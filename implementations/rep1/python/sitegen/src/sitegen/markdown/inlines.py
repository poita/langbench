"""Phase 2 of the Markdown conversion: parsing the inline content of blocks.

The parser follows the delimiter-stack / bracket-stack algorithm of the
CommonMark reference implementation.  Inline nodes form a doubly linked tree
so that wrapping a run of siblings in an emphasis, link or image node costs
one step per node moved.
"""

from __future__ import annotations

import re

from .text import (
    ASCII_PUNCTUATION,
    WHITESPACE,
    decode_entities,
    match_entity,
    unescape_backslashes,
)

# Inline node kinds.
ROOT, TEXT, SOFTBREAK, LINEBREAK, CODE, EMPH, STRONG, LINK, IMAGE = range(9)

_SPECIAL = re.compile(r"[\n`\\&<*_\[\]!]")
_BACKTICKS = re.compile(r"`+")
_URI_AUTOLINK = re.compile(r"[A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*>")
_EMAIL_AUTOLINK = re.compile(
    r"[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]"
    r"(?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    r"(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>"
)


class Inline:
    """A node of the inline tree."""

    __slots__ = ("kind", "literal", "dest", "title", "parent", "first", "last", "next", "prev")

    def __init__(self, kind: int, literal: str = "") -> None:
        self.kind = kind
        self.literal = literal
        self.dest = ""
        self.title: str | None = None
        self.parent: Inline | None = None
        self.first: Inline | None = None
        self.last: Inline | None = None
        self.next: Inline | None = None
        self.prev: Inline | None = None

    def append(self, node: Inline) -> None:
        node.parent = self
        node.prev = self.last
        node.next = None
        if self.last is None:
            self.first = node
        else:
            self.last.next = node
        self.last = node

    def unlink(self) -> None:
        parent = self.parent
        if self.prev is None:
            parent.first = self.next
        else:
            self.prev.next = self.next
        if self.next is None:
            parent.last = self.prev
        else:
            self.next.prev = self.prev
        self.parent = self.prev = self.next = None


class _Delimiter:
    """An entry of the delimiter stack (a run of ``*`` or ``_``)."""

    __slots__ = ("char", "length", "can_open", "can_close", "node", "position", "prev", "next")

    def __init__(self, char, length, can_open, can_close, node, position, prev):
        self.char = char
        self.length = length  # original run length, never updated
        self.can_open = can_open
        self.can_close = can_close
        self.node = node
        self.position = position
        self.prev = prev
        self.next = None


class _Bracket:
    """An entry of the bracket stack (``[`` or ``![``)."""

    __slots__ = ("image", "node", "position")

    def __init__(self, image: bool, node: Inline, position: int) -> None:
        self.image = image
        self.node = node
        self.position = position


class InlineParser:
    """Parses one paragraph or heading content string into an inline tree."""

    def __init__(self, content: str) -> None:
        self.s = content
        self.root = Inline(ROOT)
        self.delim_top: _Delimiter | None = None
        self.brackets: list[_Bracket] = []
        self.link_closed = True
        self.backtick_last: dict[int, int] = {}
        self.backticks_scanned = False

    # -- main loop ---------------------------------------------------------

    def parse(self) -> Inline:
        s = self.s
        n = len(s)
        pos = 0
        root = self.root
        while pos < n:
            c = s[pos]
            if c == "\n":
                kind = LINEBREAK if pos >= 2 and s[pos - 1] == " " and s[pos - 2] == " " else SOFTBREAK
                root.append(Inline(kind))
                pos += 1
                while pos < n and (s[pos] == " " or s[pos] == "\t"):
                    pos += 1
            elif c == "`":
                pos = self._code_span(pos)
            elif c == "\\":
                nxt = s[pos + 1 : pos + 2]
                if nxt and nxt in ASCII_PUNCTUATION:
                    root.append(Inline(TEXT, nxt))
                    pos += 2
                elif nxt == "\n":
                    root.append(Inline(LINEBREAK))
                    pos += 2
                else:
                    root.append(Inline(TEXT, "\\"))
                    pos += 1
            elif c == "&":
                matched = match_entity(s, pos)
                if matched is None:
                    root.append(Inline(TEXT, "&"))
                    pos += 1
                else:
                    root.append(Inline(TEXT, matched[0]))
                    pos = matched[1]
            elif c == "<":
                pos = self._autolink(pos)
            elif c == "*" or c == "_":
                pos = self._delimiter_run(pos, c)
            elif c == "[":
                node = Inline(TEXT, "[")
                root.append(node)
                pos += 1
                self.brackets.append(_Bracket(False, node, pos))
                self.link_closed = False
            elif c == "!":
                if s.startswith("[", pos + 1):
                    node = Inline(TEXT, "![")
                    root.append(node)
                    pos += 2
                    self.brackets.append(_Bracket(True, node, pos))
                else:
                    root.append(Inline(TEXT, "!"))
                    pos += 1
            elif c == "]":
                pos = self._close_bracket(pos + 1)
            else:
                found = _SPECIAL.search(s, pos)
                end = found.start() if found else n
                text = s[pos:end]
                if end < n and s[end] == "\n":
                    text = text.rstrip(WHITESPACE)
                if text:
                    root.append(Inline(TEXT, text))
                pos = end
        self._process_emphasis(0)
        return root

    # -- code spans, autolinks --------------------------------------------

    def _code_span(self, pos: int) -> int:
        s = self.s
        run = _BACKTICKS.match(s, pos)
        length = run.end() - pos
        after = run.end()
        close = self._find_closing_run(length, after)
        if close is None:
            self.root.append(Inline(TEXT, s[pos:after]))
            return after
        content = s[after:close].replace("\n", " ")
        if len(content) >= 2 and content[0] == " " and content[-1] == " " and content.strip(" "):
            content = content[1:-1]
        self.root.append(Inline(CODE, content))
        return close + length

    def _find_closing_run(self, length: int, start: int) -> int | None:
        """Find a backtick run of exactly *length* at or after *start*.

        Uses the reference implementation's memo of the last position seen
        for every run length, so a failed search is never repeated.
        """
        last = self.backtick_last
        if self.backticks_scanned and last.get(length, 0) <= start:
            return None
        for run in _BACKTICKS.finditer(self.s, start):
            k = run.end() - run.start()
            last[k] = run.start()
            if k == length:
                return run.start()
        self.backticks_scanned = True
        return None

    def _autolink(self, pos: int) -> int:
        s = self.s
        match = _URI_AUTOLINK.match(s, pos + 1)
        prefix = ""
        if match is None:
            match = _EMAIL_AUTOLINK.match(s, pos + 1)
            prefix = "mailto:"
        if match is None:
            self.root.append(Inline(TEXT, "<"))
            return pos + 1
        text = decode_entities(s[pos + 1 : match.end() - 1])
        link = Inline(LINK)
        link.dest = prefix + text
        link.append(Inline(TEXT, text))
        self.root.append(link)
        return match.end()

    # -- emphasis delimiters ----------------------------------------------

    def _delimiter_run(self, pos: int, char: str) -> int:
        s = self.s
        n = len(s)
        end = pos
        while end < n and s[end] == char:
            end += 1
        before = s[pos - 1] if pos > 0 else "\n"
        after = s[end] if end < n else "\n"
        after_space = after in WHITESPACE
        before_space = before in WHITESPACE
        after_punct = after in ASCII_PUNCTUATION
        before_punct = before in ASCII_PUNCTUATION
        left = not after_space and (not after_punct or before_space or before_punct)
        right = not before_space and (not before_punct or after_space or after_punct)
        if char == "*":
            can_open, can_close = left, right
        else:
            can_open = left and (not right or before_punct)
            can_close = right and (not left or after_punct)
        node = Inline(TEXT, s[pos:end])
        self.root.append(node)
        if can_open or can_close:
            top = _Delimiter(char, end - pos, can_open, can_close, node, end, self.delim_top)
            if self.delim_top is not None:
                self.delim_top.next = top
            self.delim_top = top
        return end

    def _remove_delimiter(self, entry: _Delimiter) -> None:
        if entry.prev is not None:
            entry.prev.next = entry.next
        if entry.next is not None:
            entry.next.prev = entry.prev
        else:
            self.delim_top = entry.prev

    def _process_emphasis(self, stack_bottom: int) -> None:
        # The entries at or above stack_bottom are a suffix of the stack.
        closer = None
        probe = self.delim_top
        while probe is not None and probe.position >= stack_bottom:
            closer = probe
            probe = probe.prev
        openers_bottom: dict[tuple[str, bool, int], int] = {}
        while closer is not None:
            if not closer.can_close:
                closer = closer.next
                continue
            kind = (closer.char, closer.can_open, closer.length % 3)
            bottom = openers_bottom.get(kind, stack_bottom)
            opener = closer.prev
            while opener is not None and opener.position >= bottom:
                if opener.can_open and opener.char == closer.char:
                    odd_match = (
                        (closer.can_open or opener.can_close)
                        and closer.length % 3 != 0
                        and (opener.length + closer.length) % 3 == 0
                    )
                    if not odd_match:
                        break
                opener = opener.prev
            else:
                opener = None
            if opener is None:
                openers_bottom[kind] = closer.position
                following = closer.next
                if not closer.can_open:
                    self._remove_delimiter(closer)
                closer = following
                continue
            closer = self._wrap_emphasis(opener, closer)
        # Forget every delimiter at or above the stack bottom.
        probe = self.delim_top
        while probe is not None and probe.position >= stack_bottom:
            probe = probe.prev
        self.delim_top = probe
        if probe is not None:
            probe.next = None

    def _wrap_emphasis(self, opener: _Delimiter, closer: _Delimiter) -> _Delimiter | None:
        """Match *opener* with *closer*; returns the next closer to examine."""
        opener_node = opener.node
        closer_node = closer.node
        use = 2 if len(opener_node.literal) >= 2 and len(closer_node.literal) >= 2 else 1
        opener_node.literal = opener_node.literal[:-use]
        closer_node.literal = closer_node.literal[use:]
        # Drop every delimiter strictly between the two.
        opener.next = closer
        closer.prev = opener
        # Wrap the nodes between the two text nodes.
        emph = Inline(STRONG if use == 2 else EMPH)
        parent = opener_node.parent
        first = opener_node.next
        if first is not closer_node:
            last = closer_node.prev
            node = first
            while True:
                node.parent = emph
                if node is last:
                    break
                node = node.next
            first.prev = None
            last.next = None
            emph.first = first
            emph.last = last
        emph.parent = parent
        emph.prev = opener_node
        emph.next = closer_node
        opener_node.next = emph
        closer_node.prev = emph
        if not opener_node.literal:
            opener_node.unlink()
            self._remove_delimiter(opener)
        if not closer_node.literal:
            closer_node.unlink()
            following = closer.next
            self._remove_delimiter(closer)
            return following
        return closer

    # -- links and images -------------------------------------------------

    def _close_bracket(self, pos: int) -> int:
        """Handle a ``]`` whose following position is *pos*."""
        root = self.root
        if not self.brackets:
            root.append(Inline(TEXT, "]"))
            return pos
        opener = self.brackets[-1]
        if not opener.image and self.link_closed:
            self.brackets.pop()
            root.append(Inline(TEXT, "]"))
            return pos
        parsed = self._inline_link_tail(pos)
        if parsed is None:
            self.brackets.pop()
            root.append(Inline(TEXT, "]"))
            return pos
        dest, title, end = parsed
        node = Inline(IMAGE if opener.image else LINK)
        node.dest = unescape_backslashes(decode_entities(dest.strip(WHITESPACE)))
        if title is not None:
            node.title = unescape_backslashes(decode_entities(title))
        # Move everything after the opener's text node into the new node.
        opener_node = opener.node
        first = opener_node.next
        if first is not None:
            last = root.last
            child = first
            while child is not None:
                child.parent = node
                child = child.next
            first.prev = None
            node.first = first
            node.last = last
            opener_node.next = None
            root.last = opener_node
        opener_node.unlink()
        root.append(node)
        self._process_emphasis(opener.position)
        self.brackets.pop()
        if not opener.image:
            self.link_closed = True
        return end

    def _inline_link_tail(self, pos: int) -> tuple[str, str | None, int] | None:
        """Parse ``(destination "title")`` starting at *pos*.

        Returns ``(raw destination, raw title or None, end position)``.
        """
        s = self.s
        n = len(s)
        if pos >= n or s[pos] != "(":
            return None
        i = self._skip_whitespace(pos + 1)
        # Destination.
        if s.startswith("<", i):
            j = i + 1
            while True:
                if j >= n:
                    return None
                ch = s[j]
                if ch == ">":
                    break
                if ch == "\\":
                    j += 2
                elif ch == "\n" or ch == "<":
                    return None
                else:
                    j += 1
            dest = s[i + 1 : j]
            i = j + 1
        else:
            j = i
            depth = 0
            while j < n:
                ch = s[j]
                if ch == "\\" and j + 1 < n and s[j + 1] in ASCII_PUNCTUATION:
                    j += 2
                elif ch == "(":
                    depth += 1
                    if depth > 32:
                        return None
                    j += 1
                elif ch == ")":
                    if depth == 0:
                        break
                    depth -= 1
                    j += 1
                elif ch in WHITESPACE:
                    break
                else:
                    j += 1
            if j >= n or depth != 0:
                return None
            dest = s[i:j]
            i = j
        # Optional title.
        title = None
        after_dest = i
        i = self._skip_whitespace(i)
        if i > after_dest and i < n and s[i] in "\"'(":
            end = self._title_end(i)
            if end is not None:
                title = s[i + 1 : end]
                i = self._skip_whitespace(end + 1)
        if i < n and s[i] == ")":
            return dest, title, i + 1
        return None

    def _skip_whitespace(self, pos: int) -> int:
        s = self.s
        n = len(s)
        while pos < n and s[pos] in WHITESPACE:
            pos += 1
        return pos

    def _title_end(self, start: int) -> int | None:
        """Index of the closing delimiter of the title opened at *start*.

        The title is the longest match of ``"(\\\\.|[^"])*"`` (likewise for
        the other delimiters): the closing character may only appear inside
        when preceded by a backslash.
        """
        s = self.s
        opener = s[start]
        closer = ")" if opener == "(" else opener
        stop = None  # the first unescaped delimiter character
        last_close = None
        j = start + 1
        n = len(s)
        while j < n:
            ch = s[j]
            if ch == closer or (opener == "(" and ch == "("):
                escaped = s[j - 1] == "\\" and j - 1 > start
                if not escaped:
                    stop = j
                    break
                if ch == closer:
                    last_close = j
            j += 1
        if stop is not None and s[stop] == closer:
            return stop
        return last_close


def parse_inlines(content: str) -> Inline:
    """Parse *content* (the raw text of a paragraph or heading)."""
    return InlineParser(content).parse()
