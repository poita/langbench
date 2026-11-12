"""The Codexa document parser: line classification, block stack, attributes."""

from __future__ import annotations

import re

from . import nodes
from .errors import CodexaError
from .inline import FootnoteCounter, scan_inline
from .units import parse_integer, parse_length

FILE = "document.cdx"

ROOT, DOC, QUOTE, BLOCK, LIST, ITEM, TABLE, PRE, FIG = range(9)

_NAME_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
_BARE_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.+-%")

_HEADINGS = {"@h1": 1, "@h2": 2, "@h3": 3, "@h4": 4,
             "@h1*": 1, "@h2*": 2, "@h3*": 3, "@h4*": 4}

#: directive -> (allowed attribute names, required attribute names)
_DIRECTIVES = {
    "@doc": ((), ()),
    "@toc": (("title",), ()),
    "@q": ((), ()),
    "@block": (("align", "indent", "right-indent", "font", "size", "leading"), ()),
    "@ul": ((), ()),
    "@ol": (("start",), ()),
    "@table": (("cols", "align"), ("cols",)),
    "@hrule": ((), ()),
    "@pre": ((), ()),
    "@fig": (("height", "width"), ("height",)),
    "@rule": ((), ()),
    "@vspace": (("height",), ("height",)),
    "@newpage": ((), ()),
    "@end": ((), ()),
}

_META_RE = re.compile(r"[ \t]*([a-z0-9-]+)[ \t]*=(.*)\Z")
_ALIGNS = ("justify", "left", "right", "center")
_FAMILIES = ("serif", "sans", "mono")

# attribute -> (kind, lo, hi)
_ATTR_KINDS = {
    ("@block", "align"): ("enum", _ALIGNS),
    ("@block", "font"): ("enum", _FAMILIES),
    ("@block", "indent"): ("length", 0, None),
    ("@block", "right-indent"): ("length", 0, None),
    ("@block", "size"): ("length", 1000, 200000),
    ("@block", "leading"): ("length", 1000, None),
    ("@ol", "start"): ("integer", 1, 100000),
    ("@table", "cols"): ("integer", 1, 20),
    ("@fig", "height"): ("length", 0, None),
    ("@fig", "width"): ("length", 0, None),
    ("@vspace", "height"): ("length", 0, None),
}


class _Frame:
    __slots__ = ("kind", "node", "children", "segs", "lineno")

    def __init__(self, kind, node=None, children=None):
        self.kind = kind
        self.node = node
        self.children = children
        self.segs = None


class _Pending:
    """A paragraph or ``@li`` text still collecting continuation lines."""

    __slots__ = ("node", "segs")

    def __init__(self, node, segs):
        self.node = node
        self.segs = segs  # list of (lineno, col index, text)


def _where_for(segs):
    """Build a ``where(i)`` for text joined from *segs* with single spaces."""
    line_of: list[int] = []
    col_of: list[int] = []
    parts: list[str] = []
    for n, (lineno, col0, text) in enumerate(segs):
        if n:
            line_of.append(segs[n - 1][0])
            col_of.append(segs[n - 1][1] + len(segs[n - 1][2]) + 1)
        for k in range(len(text)):
            line_of.append(lineno)
            col_of.append(col0 + k + 1)
        parts.append(text)
    return " ".join(parts), (lambda i: (line_of[i], col_of[i]))


class Parser:
    """Parses a Codexa document into a :class:`~typeset.nodes.Document`."""

    def __init__(self, text: str) -> None:
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        self.lines = lines
        self.counter = FootnoteCounter()
        self.doc = nodes.Document()
        self.stack = [_Frame(ROOT, children=self.doc.blocks)]
        self.pending: _Pending | None = None
        self.root_blocks = 0
        self.doc_seen = False
        self.toc_seen = False
        self.lineno = 0

    # -- errors ------------------------------------------------------------

    def err(self, code: str, idx: int, lineno: int | None = None):
        raise CodexaError(FILE, lineno or self.lineno, idx + 1, code)

    # -- driver ------------------------------------------------------------

    def parse(self) -> nodes.Document:
        for lineno, line in enumerate(self.lines, 1):
            self.lineno = lineno
            self.line(line)
        self.lineno = len(self.lines) + 1
        self.flush()
        if len(self.stack) > 1:
            self.err("missing-end", 0)
        self.doc.footnote_count = self.counter.count
        return self.doc

    def line(self, line: str) -> None:
        top = self.stack[-1]
        if top.kind == PRE:
            if line.strip(" ") == "@end":
                self.stack.pop()
            else:
                top.node.lines.append(line.rstrip(" "))
            return
        start = len(line) - len(line.lstrip(" "))
        if start == len(line):
            self.flush()
            return
        if line[start] == "@":
            self.directive(line, start)
        else:
            self.text_line(line, start)

    # -- text --------------------------------------------------------------

    def flush(self) -> None:
        p = self.pending
        if p is None:
            return
        self.pending = None
        text, where = _where_for(p.segs)
        p.node.units = scan_inline(text, where, FILE, self.counter)

    def add_block(self, node) -> None:
        top = self.stack[-1]
        if top.kind == ROOT:
            self.root_blocks += 1
        top.children.append(node)

    def text_line(self, line: str, start: int) -> None:
        top = self.stack[-1]
        kind = top.kind
        if self.pending is not None:
            self.pending.segs.append((self.lineno, start, line[start:]))
            return
        if kind in (ROOT, QUOTE, BLOCK, ITEM):
            para = nodes.Paragraph()
            self.add_block(para)
            self.pending = _Pending(para, [(self.lineno, start, line[start:])])
        elif kind == LIST:
            self.err("text-not-allowed", start)
        elif kind == TABLE:
            self.table_row(top.node, line, start)
        elif kind == DOC:
            m = _META_RE.match(line)
            if m is None:
                self.err("bad-syntax", start)
            key = m.group(1)
            if key not in ("title", "author", "date"):
                self.err("unknown-meta", m.start(1))
            if key in top.node.seen:
                self.err("duplicate-meta", m.start(1))
            top.node.seen.add(key)
            self.doc.meta[key] = m.group(2).strip(" \t")
        elif kind == FIG:
            top.segs.append((self.lineno, start, line[start:]))

    def table_row(self, table, line: str, start: int) -> None:
        cells = []
        cur = start
        i = start
        n = len(line)
        while i < n:
            c = line[i]
            if c == "\\":
                i += 2
                continue
            if c == "|":
                cells.append((cur, i))
                cur = i + 1
            i += 1
        cells.append((cur, n))
        if len(cells) != table.cols:
            self.err("cell-count", 0)
        row = []
        for s, e in cells:
            text = line[s:e]
            lineno = self.lineno
            row.append(scan_inline(text, lambda k, s=s, ln=lineno: (ln, s + k + 1),
                                   FILE, self.counter))
        table.elements.append(("row", row))

    # -- directives --------------------------------------------------------

    def parse_attrs(self, line: str, i: int, allowed):
        attrs: dict[str, tuple[str, int]] = {}
        n = len(line)
        while True:
            while i < n and line[i] == " ":
                i += 1
            if i >= n:
                break
            start = i
            while i < n and line[i] in _NAME_CHARS:
                i += 1
            if i == start or i >= n or line[i] != "=":
                self.err("bad-attribute", start)
            name = line[start:i]
            if name not in allowed or name in attrs:
                self.err("bad-attribute", start)
            i += 1
            vstart = i
            if i < n and line[i] == '"':
                j = line.find('"', i + 1)
                if j < 0:
                    self.err("bad-attribute-value", vstart)
                value = line[i + 1:j]
                i = j + 1
            else:
                while i < n and line[i] in _BARE_CHARS:
                    i += 1
                if i == vstart:
                    self.err("bad-attribute-value", vstart)
                value = line[vstart:i]
            if i < n and line[i] != " ":
                self.err("bad-attribute-value", vstart)
            attrs[name] = (value, vstart)
        return attrs

    def directive(self, line: str, at: int) -> None:
        self.flush()
        j = at
        n = len(line)
        while j < n and line[j] != " ":
            j += 1
        name = line[at:j]
        if name in _HEADINGS or name == "@li":
            self.placement(name, at)
            while j < n and line[j] == " ":
                j += 1
            if name == "@li":
                self.start_item(line, j)
            else:
                self.heading(name, line, j)
            return
        if name not in _DIRECTIVES:
            self.err("unknown-block", at)
        allowed, required = _DIRECTIVES[name]
        attrs = self.parse_attrs(line, j, allowed)
        for r in required:
            if r not in attrs:
                self.err("missing-attribute", at)
        self.placement(name, at)
        values = self.check_values(name, attrs)
        if name == "@table" and "align" in attrs:
            if len(values["align"]) != values["cols"]:
                self.err("bad-attribute-value", attrs["align"][1])
        self.open_block(name, attrs, values, at)

    def placement(self, name: str, at: int) -> None:
        top = self.stack[-1].kind
        if name == "@end":
            if top == ROOT:
                self.err("unexpected-end", at)
            return
        if top in (DOC, TABLE, FIG):
            if name == "@hrule" and top == TABLE:
                return
            self.err("block-not-allowed", at)
        if name == "@toc":
            if self.toc_seen:
                self.err("block-not-allowed" if top == LIST else "duplicate-toc", at)
            ok = top == ROOT and (self.root_blocks == 0
                                  or (self.root_blocks == 1 and self.doc_seen))
            if not ok:
                self.err("block-not-allowed", at)
            return
        if top == LIST:
            if name != "@li":
                self.err("block-not-allowed", at)
            return
        if name == "@li":
            if top != ITEM:
                self.err("block-not-allowed", at)
        elif name == "@hrule":
            self.err("block-not-allowed", at)
        elif name == "@doc":
            if not (top == ROOT and self.root_blocks == 0):
                self.err("block-not-allowed", at)

    def check_values(self, name: str, attrs) -> dict:
        values: dict = {}
        for key, (value, col) in attrs.items():
            spec = _ATTR_KINDS.get((name, key))
            if name == "@table" and key == "align":
                if not value or any(ch not in "lrc" for ch in value):
                    self.err("bad-attribute-value", col)
                values[key] = value
            elif spec is None:
                values[key] = value
            elif spec[0] == "enum":
                if value not in spec[1]:
                    self.err("bad-attribute-value", col)
                values[key] = value
            else:
                v = parse_length(value) if spec[0] == "length" else parse_integer(value)
                if v is None or v < spec[1] or (spec[2] is not None and v > spec[2]):
                    self.err("bad-attribute-value", col)
                values[key] = v
        return values

    def heading(self, name: str, line: str, j: int) -> None:
        node = nodes.Heading(_HEADINGS[name], name.endswith("*"))
        self.add_block(node)
        lineno = self.lineno
        node.units = scan_inline(line[j:], lambda k: (lineno, j + k + 1), FILE,
                                 self.counter, allow_footnote=False)

    def start_item(self, line: str, j: int) -> None:
        top = self.stack[-1]
        if top.kind == ITEM:
            self.stack.pop()
        list_frame = self.stack[-1]
        item = nodes.Item()
        list_frame.node.items.append(item)
        self.stack.append(_Frame(ITEM, item, item.children))
        self.pending = _Pending(item, [(self.lineno, j, line[j:])])

    def open_block(self, name: str, attrs, values, at: int) -> None:
        stack = self.stack
        if name == "@end":
            if stack[-1].kind == ITEM:
                stack.pop()
            frame = stack.pop()
            if frame.kind == FIG:
                text, where = _where_for(frame.segs)
                frame.node.units = scan_inline(text, where, FILE, self.counter,
                                               allow_footnote=False)
            return
        if name == "@doc":
            self.root_blocks += 1
            self.doc_seen = True
            frame = _Frame(DOC, nodes.Doc())
            frame.node.seen = set()
            stack.append(frame)
        elif name == "@toc":
            self.root_blocks += 1
            self.toc_seen = True
            self.doc.toc = nodes.Toc(values.get("title"))
        elif name == "@q":
            node = nodes.Quote()
            self.add_block(node)
            stack.append(_Frame(QUOTE, node, node.children))
        elif name == "@block":
            node = nodes.Block(values)
            self.add_block(node)
            stack.append(_Frame(BLOCK, node, node.children))
        elif name in ("@ul", "@ol"):
            node = nodes.ListNode(name == "@ol", values.get("start", 1))
            self.add_block(node)
            stack.append(_Frame(LIST, node))
        elif name == "@table":
            cols = values["cols"]
            node = nodes.Table(cols, values.get("align", "l" * cols))
            self.add_block(node)
            stack.append(_Frame(TABLE, node))
        elif name == "@hrule":
            stack[-1].node.elements.append(("hrule",))
        elif name == "@pre":
            node = nodes.Pre()
            self.add_block(node)
            stack.append(_Frame(PRE, node))
        elif name == "@fig":
            node = nodes.Figure(values["height"], values.get("width"))
            self.add_block(node)
            frame = _Frame(FIG, node)
            frame.segs = []
            stack.append(frame)
        elif name == "@rule":
            self.add_block(nodes.Rule())
        elif name == "@vspace":
            self.add_block(nodes.VSpace(values["height"]))
        elif name == "@newpage":
            self.add_block(nodes.NewPage())


def parse_document(text: str) -> nodes.Document:
    """Parse the contents of ``document.cdx``; raises :class:`CodexaError`."""
    return Parser(text).parse()
