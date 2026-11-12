"""Phase 2: parse the raw text of paragraphs and headings into inline nodes.

This follows cmark's design: a single left-to-right pass with a *delimiter
stack* for ``*``/``_`` runs and a *bracket stack* for ``[`` / ``![``, then the
"process emphasis" algorithm.  Every operation that moves nodes (wrapping them
in an emphasis or link node, dropping delimiter entries) is O(1) per element.
"""

from __future__ import annotations

import re

from .escaping import (
    PUNCTUATION,
    WHITESPACE,
    decode_entities,
    entity_value,
    match_entity,
    unescape_string,
)
from .nodes import (
    CODE,
    EMPH,
    IMAGE,
    LINEBREAK,
    LINK,
    SOFTBREAK,
    STRONG,
    TEXT,
    LinkNode,
    Node,
)
from .scanners import AUTOLINK_RE, scan_inline_link_tail

_SPECIAL_RE = re.compile(r"[\n`\\&<*_\[\]!]")
_BACKTICKS_RE = re.compile(r"`+")
_RUN_RE = {"*": re.compile(r"\*+"), "_": re.compile(r"_+")}


class _Delim:
    """A delimiter-stack entry for a run of ``*`` or ``_``."""

    __slots__ = ("ch", "length", "can_open", "can_close", "node", "position", "prev", "next")

    def __init__(self, ch, length, can_open, can_close, node, position, prev):
        self.ch = ch
        self.length = length
        self.can_open = can_open
        self.can_close = can_close
        self.node = node
        self.position = position
        self.prev = prev
        self.next = None


class _InlineParser:
    def __init__(self, block, content: str) -> None:
        self.block = block
        self.s = content
        self.last: Node | None = None  # last inline node of the block's list
        self.delims: _Delim | None = None  # top of the delimiter stack
        self.brackets: list[tuple[bool, Node, int]] = []
        self.link_closed = True
        self.backtick_last: dict[int, int] = {}
        self.backticks_scanned = False

    # -- node list --------------------------------------------------------

    def _add(self, node: Node) -> None:
        last = self.last
        if last is None:
            self.block.first_child = node
        else:
            last.next = node
            node.prev = last
        self.last = node
        self.block.last_child = node

    def _text(self, literal: str) -> Node:
        node = Node(TEXT, literal)
        self._add(node)
        return node

    # -- main loop --------------------------------------------------------

    def run(self) -> None:
        s = self.s
        n = len(s)
        pos = 0
        search = _SPECIAL_RE.search
        while pos < n:
            m = search(s, pos)
            if m is None:
                self._text(s[pos:])
                break
            i = m.start()
            ch = s[i]
            if i > pos:
                run = s[pos:i]
                if ch == "\n":
                    run = run.rstrip(WHITESPACE)
                if run:
                    self._text(run)
            if ch == "\n":
                self._add(Node(LINEBREAK if i >= 2 and s[i - 1] == " " and s[i - 2] == " " else SOFTBREAK))
                pos = i + 1
                while pos < n and s[pos] in " \t":
                    pos += 1
            elif ch == "`":
                pos = self._code_span(i)
            elif ch == "\\":
                nxt = s[i + 1] if i + 1 < n else ""
                if nxt and nxt in PUNCTUATION:
                    self._text(nxt)
                    pos = i + 2
                elif nxt == "\n":
                    self._add(Node(LINEBREAK))
                    pos = i + 2
                else:
                    self._text("\\")
                    pos = i + 1
            elif ch == "&":
                em = match_entity(s, i)
                if em is not None:
                    self._text(entity_value(em))
                    pos = em.end()
                else:
                    self._text("&")
                    pos = i + 1
            elif ch == "<":
                am = AUTOLINK_RE.match(s, i)
                if am is None:
                    self._text("<")
                    pos = i + 1
                else:
                    uri, email = am.groups()
                    text = decode_entities(uri if uri is not None else email)
                    link = LinkNode(LINK, text if uri is not None else "mailto:" + text, None)
                    child = Node(TEXT, text)
                    link.first_child = link.last_child = child
                    self._add(link)
                    pos = am.end()
            elif ch == "*" or ch == "_":
                pos = self._delimiter_run(i, ch)
            elif ch == "[":
                node = self._text("[")
                self.brackets.append((False, node, i + 1))
                self.link_closed = False
                pos = i + 1
            elif ch == "!":
                if i + 1 < n and s[i + 1] == "[":
                    node = self._text("![")
                    self.brackets.append((True, node, i + 2))
                    pos = i + 2
                else:
                    self._text("!")
                    pos = i + 1
            else:  # "]"
                pos = self._close_bracket(i)
        self._process_emphasis(0)

    # -- code spans -------------------------------------------------------

    def _code_span(self, i: int) -> int:
        s = self.s
        m = _BACKTICKS_RE.match(s, i)
        n_ticks = m.end() - i
        p = m.end()
        last = self.backtick_last
        found = -1
        if not (self.backticks_scanned and last.get(n_ticks, 0) <= p):
            for run in _BACKTICKS_RE.finditer(s, p):
                k = run.end() - run.start()
                last[k] = run.start()
                if k == n_ticks:
                    found = run.start()
                    break
            else:
                self.backticks_scanned = True
        if found < 0:
            self._text(s[i:p])
            return p
        content = s[p:found].replace("\n", " ")
        if len(content) >= 2 and content[0] == " " and content[-1] == " " and content.strip(" ") != "":
            content = content[1:-1]
        self._add(Node(CODE, content))
        return found + n_ticks

    # -- emphasis ---------------------------------------------------------

    def _delimiter_run(self, i: int, ch: str) -> int:
        s = self.s
        n = len(s)
        j = _RUN_RE[ch].match(s, i).end()
        before = s[i - 1] if i > 0 else "\n"
        after = s[j] if j < n else "\n"
        after_ws = after in WHITESPACE
        before_ws = before in WHITESPACE
        after_punct = after in PUNCTUATION
        before_punct = before in PUNCTUATION
        left = not after_ws and (not after_punct or before_ws or before_punct)
        right = not before_ws and (not before_punct or after_ws or after_punct)
        if ch == "*":
            can_open, can_close = left, right
        else:
            can_open = left and (not right or before_punct)
            can_close = right and (not left or after_punct)
        node = self._text(s[i:j])
        if can_open or can_close:
            top = self.delims
            d = _Delim(ch, j - i, can_open, can_close, node, j, top)
            if top is not None:
                top.next = d
            self.delims = d
        return j

    def _process_emphasis(self, stack_bottom: int) -> None:
        top = self.delims
        if top is None or top.position < stack_bottom:
            return
        first = top
        while first.prev is not None and first.prev.position >= stack_bottom:
            first = first.prev
        base = first.prev
        openers_bottom = [stack_bottom] * 12
        closer = first
        while closer is not None:
            if not closer.can_close:
                closer = closer.next
                continue
            c_len = closer.length
            kind = (0 if closer.ch == "*" else 6) + (3 if closer.can_open else 0) + c_len % 3
            bound = openers_bottom[kind]
            opener = closer.prev
            ch = closer.ch
            while opener is not None and opener.position >= bound:
                if opener.can_open and opener.ch == ch:
                    if not (closer.can_open or opener.can_close) or c_len % 3 == 0 or (opener.length + c_len) % 3 != 0:
                        break
                opener = opener.prev
            else:
                opener = None
            if opener is None:
                openers_bottom[kind] = closer.position
                nxt = closer.next
                if not closer.can_open:
                    self._unlink(closer)
                closer = nxt
                continue
            o_node = opener.node
            c_node = closer.node
            use = 2 if len(o_node.literal) >= 2 and len(c_node.literal) >= 2 else 1
            o_node.literal = o_node.literal[:-use]
            c_node.literal = c_node.literal[use:]
            # Drop the entries strictly between opener and closer.
            opener.next = closer
            closer.prev = opener
            # Wrap the nodes strictly between the two text nodes.
            em = Node(STRONG if use == 2 else EMPH)
            inner = o_node.next
            if inner is not c_node:
                last_inner = c_node.prev
                em.first_child = inner
                em.last_child = last_inner
                inner.prev = None
                last_inner.next = None
            em.prev = o_node
            em.next = c_node
            o_node.next = em
            c_node.prev = em
            if not o_node.literal:
                self._unlink(opener)
            if not c_node.literal:
                nxt = closer.next
                self._unlink(closer)
                closer = nxt
        # Remove every entry at or above the stack bottom.
        if base is not None:
            base.next = None
        self.delims = base

    @staticmethod
    def _unlink(d: _Delim) -> None:
        if d.prev is not None:
            d.prev.next = d.next
        if d.next is not None:
            d.next.prev = d.prev

    # -- links and images -------------------------------------------------

    def _close_bracket(self, i: int) -> int:
        brackets = self.brackets
        if not brackets:
            self._text("]")
            return i + 1
        is_image, opener, opos = brackets[-1]
        if not is_image and self.link_closed:
            brackets.pop()
            self._text("]")
            return i + 1
        tail = scan_inline_link_tail(self.s, i + 1)
        if tail is None:
            brackets.pop()
            self._text("]")
            return i + 1
        raw_dest, raw_title, end = tail
        dest = unescape_string(raw_dest.strip(WHITESPACE))
        title = unescape_string(raw_title) if raw_title is not None else None
        node = LinkNode(IMAGE if is_image else LINK, dest, title)
        first = opener.next
        if first is not None:
            node.first_child = first
            node.last_child = self.last
            first.prev = None
            opener.next = None
        opener.literal = ""
        self.last = opener
        self._add(node)
        self._process_emphasis(opos)
        brackets.pop()
        if not is_image:
            self.link_closed = True
        return end


def parse_inlines(block, content: str) -> None:
    """Parse ``content`` into inline nodes and attach them to ``block``."""
    content = content.rstrip(WHITESPACE)
    if content:
        _InlineParser(block, content).run()
