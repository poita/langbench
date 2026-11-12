"""Phase 1 of the Markdown conversion: building the tree of blocks.

A line-driven parser in the style of the CommonMark reference
implementation: every line is matched against the chain of open blocks,
then new blocks are started and the rest of the line is added to the
innermost open leaf block.
"""

from __future__ import annotations

import re

from .text import decode_entities, unescape_backslashes

# Block kinds.
DOCUMENT, BLOCKQUOTE, LIST, ITEM, PARAGRAPH, HEADING, THEMATIC, CODE = range(8)

_ATX_START = re.compile(r"(#{1,6})(?:[ \t]|$)")
_BACKTICK_FENCE = re.compile(r"`{3,}")
_TILDE_FENCE = re.compile(r"~{3,}")
_SETEXT_UNDERLINE = re.compile(r"(?:=+|-+)[ \t]*$")
_THEMATIC_BREAK = re.compile(r"([*_-])(?:[ \t]*\1){2,}[ \t]*$")
_ORDERED_MARKER = re.compile(r"([0-9]{1,9})([.)])")
_BLANKS = re.compile(r"[ \t]*")


class Block:
    """A node of the block tree."""

    __slots__ = (
        "kind", "parent", "children", "open", "start_line",
        "last_line_blank", "last_line_checked", "lines",
        # lists and items
        "ordered", "marker", "start", "tight", "marker_offset", "padding",
        # headings
        "level", "setext",
        # code blocks
        "fenced", "fence_char", "fence_length", "fence_offset", "info", "text",
    )

    def __init__(self, kind: int, parent: Block | None = None, start_line: int = 0) -> None:
        self.kind = kind
        self.parent = parent
        self.children: list[Block] = []
        self.open = True
        self.start_line = start_line
        self.last_line_blank = False
        self.last_line_checked = False
        self.lines: list[str] = []
        self.ordered = False
        self.marker = ""
        self.start = 1
        self.tight = True
        self.marker_offset = 0
        self.padding = 0
        self.level = 0
        self.setext = False
        self.fenced = False
        self.fence_char = ""
        self.fence_length = 0
        self.fence_offset = 0
        self.info = ""
        self.text = ""

    @property
    def content(self) -> str:
        """The raw text accumulated by a paragraph or heading."""
        return "".join(self.lines)


def _can_contain(parent_kind: int, child_kind: int) -> bool:
    if parent_kind == LIST:
        return child_kind == ITEM
    if parent_kind in (DOCUMENT, BLOCKQUOTE, ITEM):
        return child_kind != ITEM
    return False


def _accepts_lines(kind: int) -> bool:
    return kind == PARAGRAPH or kind == HEADING or kind == CODE


def _ends_with_blank_line(block: Block) -> bool:
    """cmark's memoised test for "this block ends with a blank line"."""
    if block.last_line_checked:
        return block.last_line_blank
    block.last_line_checked = True
    if block.kind in (LIST, ITEM) and block.children:
        return _ends_with_blank_line(block.children[-1])
    return block.last_line_blank


class BlockParser:
    """Parses a whole document into a tree of :class:`Block` nodes."""

    def __init__(self) -> None:
        self.root = Block(DOCUMENT)
        self.current = self.root  # the innermost open block (the "tip")
        self.line = ""
        self.line_number = 0
        self.offset = 0
        self.column = 0
        self.partial_tab = False
        # Results of find_first_nonspace().
        self.first_nonspace = 0
        self.indent = 0
        self.blank = False

    # -- driver ------------------------------------------------------------

    def parse(self, text: str) -> Block:
        lines = text.split("\n")
        if lines[-1] == "":
            lines.pop()
        for line in lines:
            self._process_line(line)
        block: Block | None = self.current
        while block is not None:
            block = self._finalize(block)
        return self.root

    # -- column bookkeeping -------------------------------------------------

    def _find_first_nonspace(self) -> None:
        line = self.line
        start = self.offset
        pos = _BLANKS.match(line, start).end()
        skipped = line[start:pos]
        if "\t" in skipped:
            column = self.column
            chars_to_tab = 4 - (column % 4)
            for ch in skipped:
                if ch == " ":
                    column += 1
                    chars_to_tab -= 1
                    if chars_to_tab == 0:
                        chars_to_tab = 4
                else:
                    column += chars_to_tab
                    chars_to_tab = 4
            self.indent = column - self.column
        else:
            self.indent = len(skipped)
        self.first_nonspace = pos
        self.blank = pos >= len(line)

    def _advance(self, count: int, columns: bool) -> None:
        """Consume *count* characters, or *count* columns when *columns*."""
        line = self.line
        n = len(line)
        while count > 0 and self.offset < n:
            if line[self.offset] == "\t":
                chars_to_tab = 4 - (self.column % 4)
                if columns:
                    self.partial_tab = chars_to_tab > count
                    step = min(count, chars_to_tab)
                    self.column += step
                    if not self.partial_tab:
                        self.offset += 1
                    count -= step
                else:
                    self.partial_tab = False
                    self.column += chars_to_tab
                    self.offset += 1
                    count -= 1
            else:
                self.partial_tab = False
                self.offset += 1
                self.column += 1
                count -= 1

    def _rest_of_line(self) -> str:
        if self.partial_tab:
            return " " * (4 - (self.column % 4)) + self.line[self.offset + 1 :]
        return self.line[self.offset :]

    def _peek(self, pos: int) -> str:
        return self.line[pos : pos + 1]

    # -- tree manipulation --------------------------------------------------

    def _add_child(self, parent: Block, kind: int) -> Block:
        while not _can_contain(parent.kind, kind):
            parent = self._finalize(parent)
        child = Block(kind, parent, self.line_number)
        parent.children.append(child)
        return child

    def _finalize(self, block: Block) -> Block | None:
        """Close *block* (only that block) and return its parent."""
        parent = block.parent
        if not block.open:
            return parent
        block.open = False
        kind = block.kind
        if kind == CODE:
            self._finalize_code(block)
        elif kind == LIST:
            self._finalize_list(block)
        return parent

    @staticmethod
    def _finalize_code(block: Block) -> None:
        lines = block.lines
        if block.fenced:
            if lines:
                info = lines[0].rstrip("\n")
                info = unescape_backslashes(decode_entities(info).strip(" \t\n\x0b\x0c\r"))
                block.info = info
                block.text = "".join(lines[1:])
            return
        text = "".join(lines)
        keep = len(text.rstrip(" \t\n"))
        if keep == 0:
            text = ""
        else:
            cut = text.find("\n", keep)
            if cut != -1:
                text = text[:cut]
        block.text = text + "\n"

    @staticmethod
    def _finalize_list(block: Block) -> None:
        items = block.children
        last = len(items) - 1
        for index, item in enumerate(items):
            if item.last_line_blank and index < last:
                block.tight = False
                return
            children = item.children
            for sub_index, sub in enumerate(children):
                if (index < last or sub_index < len(children) - 1) and _ends_with_blank_line(sub):
                    block.tight = False
                    return

    # -- one line ------------------------------------------------------------

    def _process_line(self, line: str) -> None:
        self.line = line
        self.line_number += 1
        self.offset = 0
        self.column = 0
        self.partial_tab = False

        # Step 1: continue open blocks.
        all_matched = True
        container = self.root
        while container.children and container.children[-1].open:
            container = container.children[-1]
            self._find_first_nonspace()
            kind = container.kind
            if kind == BLOCKQUOTE:
                if self.indent <= 3 and self._peek(self.first_nonspace) == ">":
                    self._advance(self.first_nonspace + 1 - self.offset, False)
                    if self._peek(self.offset) in (" ", "\t"):
                        self._advance(1, True)
                else:
                    all_matched = False
            elif kind == ITEM:
                needed = container.marker_offset + container.padding
                if self.indent >= needed:
                    self._advance(needed, True)
                elif self.blank and container.children:
                    self._advance(self.first_nonspace - self.offset, False)
                else:
                    all_matched = False
            elif kind == CODE:
                if not container.fenced:
                    if self.indent >= 4:
                        self._advance(4, True)
                    elif self.blank:
                        self._advance(self.first_nonspace - self.offset, False)
                    else:
                        all_matched = False
                else:
                    if self.indent <= 3 and self._closes_fence(container):
                        self._finalize(container)
                        self.current = container.parent
                        return
                    skip = container.fence_offset
                    while skip > 0 and self._peek(self.offset) in (" ", "\t"):
                        self._advance(1, True)
                        skip -= 1
            elif kind == HEADING:
                all_matched = False
            elif kind == PARAGRAPH:
                if self.blank:
                    all_matched = False
            if not all_matched:
                container = container.parent
                break
        last_matched = container

        # Step 2: start new blocks.
        maybe_lazy = self.current.kind == PARAGRAPH
        while container.kind != CODE:
            self._find_first_nonspace()
            indented = self.indent >= 4
            fns = self.first_nonspace
            line = self.line
            ch = line[fns : fns + 1]
            match = None
            if not indented and ch == ">":
                self._advance(fns + 1 - self.offset, False)
                if self._peek(self.offset) in (" ", "\t"):
                    self._advance(1, True)
                container = self._add_child(container, BLOCKQUOTE)
            elif not indented and ch == "#" and (match := _ATX_START.match(line, fns)):
                self._advance(match.end(1) - self.offset, False)
                while self._peek(self.offset) in (" ", "\t"):
                    self._advance(1, False)
                container = self._add_child(container, HEADING)
                container.level = match.end(1) - fns
            elif (
                not indented
                and (ch == "`" or ch == "~")
                and (match := (_BACKTICK_FENCE if ch == "`" else _TILDE_FENCE).match(line, fns))
                and (ch == "~" or "`" not in line[match.end() :])
            ):
                fence_length = match.end() - fns
                fence_offset = fns - self.offset
                self._advance(match.end() - self.offset, False)
                container = self._add_child(container, CODE)
                container.fenced = True
                container.fence_char = ch
                container.fence_length = fence_length
                container.fence_offset = fence_offset
            elif (
                not indented
                and container.kind == PARAGRAPH
                and (ch == "=" or ch == "-")
                and _SETEXT_UNDERLINE.match(line, fns)
            ):
                container.kind = HEADING
                container.level = 1 if ch == "=" else 2
                container.setext = True
                self._advance(len(line) - self.offset, False)
            elif not indented and (ch == "*" or ch == "_" or ch == "-") and _THEMATIC_BREAK.match(line, fns):
                container = self._add_child(container, THEMATIC)
                self._advance(len(line) - self.offset, False)
            elif self.indent < 4 and (marker := self._parse_list_marker(fns, container.kind == PARAGRAPH)):
                container = self._start_list_item(container, marker)
            elif indented and not maybe_lazy and not self.blank:
                self._advance(4, True)
                container = self._add_child(container, CODE)
            else:
                break
            if _accepts_lines(container.kind):
                break
            maybe_lazy = False

        # Step 3: add the text of the line.
        self._find_first_nonspace()
        blank = self.blank
        kind = container.kind
        if blank and container.children:
            container.children[-1].last_line_blank = True
        container.last_line_blank = blank and not (
            kind == BLOCKQUOTE
            or kind == HEADING
            or kind == THEMATIC
            or (kind == CODE and container.fenced)
            or (kind == ITEM and not container.children and container.start_line == self.line_number)
        )
        ancestor = container.parent
        while ancestor is not None:
            ancestor.last_line_blank = False
            ancestor = ancestor.parent

        tip = self.current
        if tip is not last_matched and container is last_matched and not blank and tip.kind == PARAGRAPH:
            # Lazy continuation line.
            tip.lines.append(self._rest_of_line() + "\n")
            return
        while self.current is not last_matched:
            self.current = self._finalize(self.current)
        if kind == CODE:
            container.lines.append(self._rest_of_line() + "\n")
        elif blank:
            pass
        elif kind == HEADING or kind == PARAGRAPH:
            rest = self._rest_of_line().lstrip(" \t")
            if kind == HEADING and not container.setext:
                rest = self._chop_closing_hashes(rest)
            container.lines.append(rest + "\n")
        else:
            container = self._add_child(container, PARAGRAPH)
            container.lines.append(self._rest_of_line().lstrip(" \t") + "\n")
        self.current = container

    def _closes_fence(self, block: Block) -> bool:
        line = self.line
        pos = self.first_nonspace
        char = block.fence_char
        end = pos
        n = len(line)
        while end < n and line[end] == char:
            end += 1
        return end - pos >= block.fence_length and not line[end:].strip(" \t")

    def _parse_list_marker(self, pos: int, interrupts_paragraph: bool):
        """Return ``(width, ordered, marker char, number)`` or ``None``."""
        line = self.line
        ch = line[pos : pos + 1]
        if ch in ("*", "+", "-"):
            width, ordered, marker, number = 1, False, ch, 1
        elif ch.isdigit():
            match = _ORDERED_MARKER.match(line, pos)
            if match is None:
                return None
            number = int(match.group(1))
            if interrupts_paragraph and number != 1:
                return None
            width, ordered, marker = match.end() - pos, True, match.group(2)
        else:
            return None
        after = pos + width
        nxt = line[after : after + 1]
        if nxt not in ("", " ", "\t"):
            return None
        if interrupts_paragraph and not line[after:].strip(" \t"):
            return None
        return width, ordered, marker, number

    def _start_list_item(self, container: Block, marker) -> Block:
        width, ordered, char, number = marker
        marker_offset = self.indent
        self._advance(self.first_nonspace + width - self.offset, False)
        saved = (self.offset, self.column, self.partial_tab)
        start_column = self.column
        while self.column - start_column <= 5 and self._peek(self.offset) in (" ", "\t"):
            self._advance(1, True)
        spaces = self.column - start_column
        if spaces >= 5 or spaces < 1 or self.offset >= len(self.line):
            padding = width + 1
            self.offset, self.column, self.partial_tab = saved
            if spaces > 0:
                self._advance(1, True)
        else:
            padding = width + spaces
        if not (
            container.kind == LIST
            and container.ordered == ordered
            and container.marker == char
        ):
            container = self._add_child(container, LIST)
            container.ordered = ordered
            container.marker = char
            container.start = number
        item = self._add_child(container, ITEM)
        item.marker_offset = marker_offset
        item.padding = padding
        return item

    @staticmethod
    def _chop_closing_hashes(rest: str) -> str:
        """Remove an ATX heading's optional closing run of ``#``."""
        rest = rest.rstrip(" \t")
        stripped = rest.rstrip("#")
        if len(stripped) != len(rest) and (not stripped or stripped[-1] in " \t"):
            return stripped.rstrip(" \t")
        return rest


def parse_blocks(text: str) -> Block:
    """Parse *text* into a block tree and return its document node."""
    return BlockParser().parse(text)
