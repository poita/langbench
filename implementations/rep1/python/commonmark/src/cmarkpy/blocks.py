"""Phase 1: build the block structure, line by line (cmark style).

The parser keeps the chain of open blocks from the document down to the
*tip*.  Each input line is matched against that chain, new blocks are opened
and the remainder of the line is added to the innermost open leaf.  Leaf
text (paragraphs and headings) is handed to :mod:`cmarkpy.inlines` once the
whole tree is built.
"""

from __future__ import annotations

import re

from .escaping import WHITESPACE, decode_entities, unescape_backslashes
from .nodes import (
    BLOCK_QUOTE,
    CODE_BLOCK,
    DOCUMENT,
    HEADING,
    ITEM,
    LIST,
    PARAGRAPH,
    THEMATIC_BREAK,
    Block,
)

_ATX_RE = re.compile(r"#{1,6}(?=[ \t]|\Z)")
_FENCE_RE = re.compile(r"(?:`{3,}(?=[^`]*\Z)|~{3,})")
_SETEXT_RE = re.compile(r"(?:=+|-+)[ \t]*\Z")
_THEMATIC_RE = re.compile(r"([*_-])(?:[ \t]*\1){2,}[ \t]*\Z")
_DIGITS_RE = re.compile(r"[0-9]{1,9}")


def _can_contain(parent_type: int, child_type: int) -> bool:
    if parent_type == LIST:
        return child_type == ITEM
    if parent_type in (DOCUMENT, BLOCK_QUOTE, ITEM):
        return child_type != ITEM
    return False


class BlockParser:
    """Incremental block-structure parser.  Use :meth:`parse`."""

    def __init__(self) -> None:
        self.doc = Block(DOCUMENT)
        self.tip = self.doc
        #: Paragraphs and headings, in the order they were closed.
        self.leaves: list[Block] = []
        self.line_no = 0
        # Per-line scanning state.
        self.line = ""
        self.n = 0
        self.offset = 0
        self.column = 0
        self.ptab = False  # a tab at ``offset`` is partially consumed
        self.nns = 0  # cached index of the next non-space/tab character
        self.nns_col = 0
        self.indent = 0
        self.blank = False

    # -- public ---------------------------------------------------------

    def parse(self, text: str) -> Block:
        """Parse ``text`` and return the document block."""
        if text:
            lines = text.split("\n")
            if text.endswith("\n"):
                lines.pop()
            for line in lines:
                self._process_line(line)
        self._close_through(self.doc)
        return self.doc

    # -- scanning helpers -------------------------------------------------

    def _find_nonspace(self) -> None:
        if self.nns <= self.offset:
            line = self.line
            n = self.n
            i = self.offset
            col = self.column
            while i < n:
                c = line[i]
                if c == " ":
                    col += 1
                elif c == "\t":
                    col += 4 - (col & 3)
                else:
                    break
                i += 1
            self.nns = i
            self.nns_col = col
        self.indent = self.nns_col - self.column
        self.blank = self.nns >= self.n

    def _advance(self, count: int, columns: bool) -> None:
        line = self.line
        n = self.n
        offset = self.offset
        column = self.column
        ptab = self.ptab
        while count > 0 and offset < n:
            if line[offset] == "\t":
                to_tab = 4 - (column & 3)
                if columns:
                    ptab = to_tab > count
                    adv = count if count < to_tab else to_tab
                    column += adv
                    if adv >= to_tab:
                        offset += 1
                    count -= adv
                else:
                    ptab = False
                    column += to_tab
                    offset += 1
                    count -= 1
            else:
                ptab = False
                offset += 1
                column += 1
                count -= 1
        self.offset = offset
        self.column = column
        self.ptab = ptab

    def _rest(self) -> str:
        """The rest of the line, expanding a partially consumed tab."""
        if self.ptab:
            return " " * (4 - (self.column & 3)) + self.line[self.offset + 1 :]
        return self.line[self.offset :]

    # -- tree helpers -----------------------------------------------------

    def _add_child(self, parent: Block, type: int) -> Block:
        while not _can_contain(parent.type, type):
            self._close_through(parent)
            parent = parent.parent
        node = Block(type)
        node.parent = parent
        node.start_line = self.line_no
        last = parent.last_child
        if last is None:
            parent.first_child = node
        else:
            last.next = node
            node.prev = last
        parent.last_child = node
        return node

    def _close_through(self, block: Block) -> None:
        """Finalize the open chain from the tip up to and including ``block``."""
        tip = self.tip
        while True:
            self._finalize(tip)
            parent = tip.parent
            if tip is block:
                self.tip = parent if parent is not None else tip
                return
            tip = parent

    def _finalize(self, b: Block) -> None:
        b.open = False
        t = b.type
        if t == PARAGRAPH or t == HEADING:
            self.leaves.append(b)
        elif t == CODE_BLOCK:
            self._finalize_code(b)
        elif t == LIST:
            self._finalize_list(b)

    @staticmethod
    def _finalize_code(b: Block) -> None:
        lines = b.lines
        if b.fenced:
            if lines:
                info = decode_entities(lines[0][:-1]).strip(WHITESPACE)
                b.info = unescape_backslashes(info)
                del lines[0]
            b.literal = "".join(lines)
        else:
            text = "".join(lines)
            i = len(text) - 1
            while i >= 0 and text[i] in " \t\n":
                i -= 1
            if i < 0:
                text = ""
            else:
                nl = text.find("\n", i)
                if nl >= 0:
                    text = text[:nl]
            b.literal = text + "\n"
        b.lines = []

    @staticmethod
    def _ends_with_blank_line(node: Block | None) -> bool:
        # Mirrors cmark's memoised S_ends_with_blank_line.
        while node is not None:
            if node.checked:
                return node.last_line_blank
            node.checked = True
            if (node.type == LIST or node.type == ITEM) and node.last_child is not None:
                node = node.last_child
            else:
                return node.last_line_blank
        return False

    def _finalize_list(self, lst: Block) -> None:
        item = lst.first_child
        while item is not None:
            if item.last_line_blank and item.next is not None:
                lst.tight = False
                return
            sub = item.first_child
            while sub is not None:
                if (item.next is not None or sub.next is not None) and self._ends_with_blank_line(sub):
                    lst.tight = False
                    return
                sub = sub.next
            item = item.next

    # -- list markers -----------------------------------------------------

    def _parse_list_marker(self, interrupts_paragraph: bool):
        """Return ``(ordered, marker, start, width)`` or ``None``."""
        line = self.line
        n = self.n
        pos = self.nns
        c = line[pos]
        if c in "*-+":
            pos += 1
            if pos < n and line[pos] not in " \t":
                return None
            if interrupts_paragraph and not line[pos:].strip(" \t"):
                return None
            return False, c, 0, 1
        m = _DIGITS_RE.match(line, pos)
        if m is None:
            return None
        pos = m.end()
        if pos >= n or line[pos] not in ".)":
            return None
        delim = line[pos]
        start = int(m.group())
        pos += 1
        if pos < n and line[pos] not in " \t":
            return None
        if interrupts_paragraph and (start != 1 or not line[pos:].strip(" \t")):
            return None
        return True, delim, start, m.end() - self.nns + 1

    # -- line processing --------------------------------------------------

    def _process_line(self, line: str) -> None:
        self.line = line
        n = self.n = len(line)
        self.line_no += 1
        self.offset = 0
        self.column = 0
        self.ptab = False
        self.nns = 0
        self.nns_col = 0

        # Step 1: continue open blocks.
        container = self.doc
        all_matched = True
        while True:
            child = container.last_child
            if child is None or not child.open:
                break
            self._find_nonspace()
            t = child.type
            if t == BLOCK_QUOTE:
                if self.indent <= 3 and self.nns < n and line[self.nns] == ">":
                    self._advance(self.indent + 1, True)
                    if self.offset < n and line[self.offset] in " \t":
                        self._advance(1, True)
                else:
                    all_matched = False
                    break
            elif t == ITEM:
                if self.indent >= child.marker_offset + child.padding:
                    self._advance(child.marker_offset + child.padding, True)
                elif self.blank and child.first_child is not None:
                    self._advance(self.nns - self.offset, False)
                else:
                    all_matched = False
                    break
            elif t == CODE_BLOCK:
                if child.fenced:
                    if self.indent <= 3 and self.nns < n and line[self.nns] == child.fence_char:
                        j = self.nns
                        c = child.fence_char
                        while j < n and line[j] == c:
                            j += 1
                        if j - self.nns >= child.fence_len and not line[j:].strip(" \t"):
                            self._close_through(child)
                            return
                    i = child.fence_offset
                    while i > 0 and self.offset < n and line[self.offset] in " \t":
                        self._advance(1, True)
                        i -= 1
                elif self.indent >= 4:
                    self._advance(4, True)
                elif self.blank:
                    self._advance(self.nns - self.offset, False)
                else:
                    all_matched = False
                    break
            elif t == HEADING:
                all_matched = False
                break
            elif t == PARAGRAPH:
                if self.blank:
                    all_matched = False
                    break
            # LIST and THEMATIC_BREAK always continue.
            container = child
        last_matched = container

        # Step 2: start new blocks.
        maybe_lazy = self.tip.type == PARAGRAPH
        while container.type != CODE_BLOCK:
            self._find_nonspace()
            if self.blank:
                break
            nns = self.nns
            indented = self.indent >= 4
            c = line[nns]
            if not indented:
                if c == ">":
                    self._advance(nns + 1 - self.offset, False)
                    if self.offset < n and line[self.offset] in " \t":
                        self._advance(1, True)
                    container = self._add_child(container, BLOCK_QUOTE)
                    maybe_lazy = False
                    continue
                if c == "#":
                    m = _ATX_RE.match(line, nns)
                    if m is not None:
                        j = m.end()
                        while j < n and line[j] in " \t":
                            j += 1
                        self._advance(j - self.offset, False)
                        container = self._add_child(container, HEADING)
                        container.level = m.end() - nns
                        break
                if c == "`" or c == "~":
                    m = _FENCE_RE.match(line, nns)
                    if m is not None:
                        length = m.end() - nns
                        offset_in_line = nns - self.offset
                        self._advance(m.end() - self.offset, False)
                        container = self._add_child(container, CODE_BLOCK)
                        container.fenced = True
                        container.fence_char = c
                        container.fence_len = length
                        container.fence_offset = offset_in_line
                        break
                if (c == "=" or c == "-") and container.type == PARAGRAPH:
                    if _SETEXT_RE.match(line, nns) is not None:
                        container.type = HEADING
                        container.level = 1 if c == "=" else 2
                        self._advance(n - self.offset, False)
                        break
                if c == "*" or c == "_" or c == "-":
                    if _THEMATIC_RE.match(line, nns) is not None:
                        container = self._add_child(container, THEMATIC_BREAK)
                        self._advance(n - self.offset, False)
                        break
                if c in "*-+" or "0" <= c <= "9":
                    marker = self._parse_list_marker(container.type == PARAGRAPH)
                    if marker is not None:
                        ordered, mchar, start, width = marker
                        marker_offset = self.indent
                        self._advance(nns + width - self.offset, False)
                        sp_offset, sp_col, sp_ptab = self.offset, self.column, self.ptab
                        while self.column - sp_col <= 5 and self.offset < n and line[self.offset] in " \t":
                            self._advance(1, True)
                        spaces = self.column - sp_col
                        if spaces >= 5 or spaces < 1 or self.offset >= n:
                            padding = width + 1
                            self.offset, self.column, self.ptab = sp_offset, sp_col, sp_ptab
                            if spaces > 0:
                                self._advance(1, True)
                        else:
                            padding = width + spaces
                        if not (container.type == LIST and container.ordered == ordered and container.marker == mchar):
                            container = self._add_child(container, LIST)
                            container.ordered = ordered
                            container.marker = mchar
                            container.start = start
                            container.tight = True
                        container = self._add_child(container, ITEM)
                        container.marker_offset = marker_offset
                        container.padding = padding
                        maybe_lazy = False
                        continue
            elif not maybe_lazy:
                self._advance(4, True)
                container = self._add_child(container, CODE_BLOCK)
                break
            break

        # Step 3: add the text of the line.
        self._find_nonspace()
        blank = self.blank
        if blank and container.last_child is not None:
            container.last_child.last_line_blank = True
        t = container.type
        container.last_line_blank = (
            blank
            and t != BLOCK_QUOTE
            and t != HEADING
            and t != THEMATIC_BREAK
            and not (t == CODE_BLOCK and container.fenced)
            and not (t == ITEM and container.first_child is None and container.start_line == self.line_no)
        )
        p = container.parent
        while p is not None:
            p.last_line_blank = False
            p = p.parent

        tip = self.tip
        if not all_matched and container is last_matched and not blank and tip.type == PARAGRAPH:
            tip.lines.append(self._rest() + "\n")
            return
        while last_matched.open and self.tip is not last_matched:
            self._close_through(self.tip)
        if t == CODE_BLOCK:
            container.lines.append(self._rest() + "\n")
        elif blank:
            pass
        else:
            if t == HEADING:
                content = _chop_trailing_hashes(line[self.offset :])
            else:
                if t != PARAGRAPH:
                    container = self._add_child(container, PARAGRAPH)
                self._advance(self.nns - self.offset, False)
                content = self._rest()
            container.lines.append(content + "\n")
        self.tip = container


def _chop_trailing_hashes(text: str) -> str:
    """Strip an ATX heading's optional closing ``#`` sequence."""
    text = text.rstrip(WHITESPACE)
    stripped = text.rstrip("#")
    if len(stripped) != len(text) and (not stripped or stripped[-1] in " \t"):
        return stripped.rstrip(WHITESPACE)
    return text
