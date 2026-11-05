"""The Codexa document parser: blocks, attributes and inline markup.

The parser produces a tree of Node objects whose inline content is already
resolved into styled unit streams, and a flat list of footnotes in source
order.
"""

from settings import CodexaError, ALIGNS, FAMILIES, parse_length, parse_integer

DOC_FILE = "document.cdx"

# Inline style: (mono, bold, italic, size-step operations in application order).
BASE_STYLE = (False, False, False, ())

TAGS = "bim+-n"

ESCAPABLE = "{}|\\@~ "

NAME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
BARE_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-%")

BLOCK_NAMES = [
    "@doc", "@toc", "@h1", "@h2", "@h3", "@h4", "@q", "@block", "@ul", "@ol",
    "@li", "@table", "@hrule", "@pre", "@fig", "@rule", "@vspace", "@newpage",
    "@end",
]

INLINE_DIRECTIVES = ("@h1", "@h2", "@h3", "@h4", "@li")

ATTRS = {
    "@doc": [],
    "@toc": ["title"],
    "@q": [],
    "@block": ["align", "indent", "right-indent", "font", "size", "leading"],
    "@ul": [],
    "@ol": ["start"],
    "@table": ["cols", "align"],
    "@hrule": [],
    "@pre": [],
    "@fig": ["height", "width"],
    "@rule": [],
    "@vspace": ["height"],
    "@newpage": [],
    "@end": [],
    "@h1": [], "@h2": [], "@h3": [], "@h4": [], "@li": [],
}

REQUIRED = {"@table": ["cols"], "@fig": ["height"], "@vspace": ["height"]}


class Node:
    """One block of the document tree."""

    def __init__(self, kind, **fields):
        self.kind = kind
        self.children = []
        self.__dict__.update(fields)


class Footnote:
    """One `{n|...}` construct: its number and its own unit stream."""

    def __init__(self, number, units):
        self.number = number
        self.units = units


class Document:
    def __init__(self):
        self.meta = {"title": "", "author": "", "date": ""}
        self.has_toc = False
        self.toc_title = None
        self.blocks = []
        self.footnotes = []
        self.counts = {
            "paragraphs": 0, "headings": 0, "tables": 0, "figures": 0,
        }
        self.figures = []


def style_push(style, tag):
    mono, bold, italic, ops = style
    if tag == "b":
        return (mono, True, italic, ops)
    if tag == "i":
        return (mono, bold, True, ops)
    if tag == "m":
        return (True, bold, italic, ops)
    if tag == "+":
        return (mono, bold, italic, ops + (1,))
    if tag == "-":
        return (mono, bold, italic, ops + (-1,))
    return style


class InlineScanner:
    """Scans a character stream (with source positions) into styled units."""

    def __init__(self, chars, doc, allow_footnotes):
        self.chars = chars
        self.doc = doc
        self.allow_footnotes = allow_footnotes

    def error(self, index, code):
        _ch, lineno, col = self.chars[index]
        return CodexaError(DOC_FILE, lineno, col, code)

    def scan(self, start, style, open_at, in_footnote):
        """Scan from `start` until an unmatched '}' or the end of the stream.

        `open_at` is the index of the '{' this level belongs to, or None at the
        top level; it is the position reported for `unclosed-inline`.
        """
        units = []
        i = start
        chars = self.chars
        n = len(chars)
        while i < n:
            ch = chars[i][0]
            if ch == "}":
                if open_at is None:
                    raise self.error(i, "stray-brace")
                return units, i
            if ch == "{":
                if i + 2 >= n or chars[i + 1][0] not in TAGS or chars[i + 2][0] != "|":
                    raise self.error(i, "unknown-inline")
                tag = chars[i + 1][0]
                if tag == "n":
                    if in_footnote:
                        raise self.error(i, "nested-footnote")
                    if not self.allow_footnotes:
                        raise self.error(i, "footnote-not-allowed")
                    number = len(self.doc.footnotes) + 1
                    note = Footnote(number, [])
                    self.doc.footnotes.append(note)
                    inner, j = self.scan(i + 3, BASE_STYLE, i, True)
                    note.units = inner
                    units.append(("mark", number, style))
                else:
                    inner, j = self.scan(i + 3, style_push(style, tag), i, in_footnote)
                    units.extend(inner)
                i = j + 1
                continue
            if ch == "\\":
                if i + 1 >= n:
                    raise self.error(i, "bad-escape")
                nxt = chars[i + 1][0]
                if nxt == "-":
                    units.append(("disc", style))
                elif nxt == " ":
                    units.append(("rig", style))
                elif nxt in ESCAPABLE:
                    units.append(("ch", nxt, style))
                else:
                    raise self.error(i, "bad-escape")
                i += 2
                continue
            if ch == "~":
                units.append(("rig", style))
                i += 1
                continue
            if ch == " ":
                units.append(("sp", style))
                i += 1
                continue
            units.append(("ch", ch, style))
            i += 1
        if open_at is not None:
            raise self.error(open_at, "unclosed-inline")
        return units, n


def segment_chars(segments):
    """Flatten (lineno, col, text) segments, joining them with one space."""
    chars = []
    for index, (lineno, col, text) in enumerate(segments):
        if index > 0:
            chars.append((" ", lineno, col))
        for offset, ch in enumerate(text):
            chars.append((ch, lineno, col + offset))
    return chars


def scan_inline(segments, doc, allow_footnotes):
    chars = segment_chars(segments)
    scanner = InlineScanner(chars, doc, allow_footnotes)
    units, _end = scanner.scan(0, BASE_STYLE, None, False)
    return units


def literal_units(text, style=BASE_STYLE):
    """Turn a plain string into units, with spaces as spaces and no markup."""
    out = []
    for ch in text:
        out.append(("sp", style) if ch == " " else ("ch", ch, style))
    return out


def plain_text(units):
    """The plain text of a unit stream: tags dropped, space runs collapsed."""
    out = []
    for unit in units:
        kind = unit[0]
        if kind == "ch":
            out.append(unit[1])
        elif kind in ("sp", "rig"):
            out.append(" ")
    return collapse_spaces("".join(out))


def collapse_spaces(text):
    """Replace every run of spaces with one space and strip the ends."""
    return " ".join(part for part in text.split(" ") if part)


class Frame:
    """One entry of the open-block stack."""

    def __init__(self, kind, node, implicit=False, at=None):
        self.kind = kind
        self.node = node
        self.implicit = implicit
        self.at = at
        self.segments = []
        self.pending_kind = None
        self.pending_node = None


class Parser:
    def __init__(self, text, settings):
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        self.lines = lines
        self.settings = settings
        self.doc = Document()
        self.index = 0

    # -- low level helpers ------------------------------------------------

    def err(self, lineno, col, code):
        return CodexaError(DOC_FILE, lineno, col, code)

    def parse(self):
        doc = self.doc
        root = Node("root")
        self.stack = [Frame("root", root)]
        self.root_blocks = 0
        self.seen_doc = False
        self.seen_toc = False
        lines = self.lines
        i = 0
        while i < len(lines):
            line = lines[i]
            top = self.stack[-1]
            if top.kind == "pre":
                if line.strip(" ") == "@end":
                    self.close_block(i + 1, 1)
                    i += 1
                    continue
                top.node.lines.append(line.rstrip(" "))
                i += 1
                continue
            stripped = line.lstrip(" ")
            if stripped == "":
                self.flush_inline()
                i += 1
                continue
            col0 = len(line) - len(stripped) + 1
            if stripped[0] == "@":
                self.flush_inline()
                i = self.directive(i, line, col0)
                continue
            i = self.text_line(i, line, col0)
        self.flush_inline()
        while len(self.stack) > 1:
            frame = self.stack[-1]
            if frame.implicit:
                self.close_block(len(lines) + 1, 1)
                continue
            raise self.err(len(lines) + 1, 1, "missing-end")
        doc.blocks = root.children
        return doc

    # -- inline accumulation ---------------------------------------------

    def flush_inline(self):
        """Finish the inline block whose continuation lines have just ended."""
        frame = self.stack[-1]
        if frame.pending_kind is None:
            return
        kind = frame.pending_kind
        segments = frame.segments
        frame.pending_kind = None
        frame.segments = []
        if kind == "para":
            units = scan_inline(segments, self.doc, True)
            node = Node("para", units=units)
            frame.node.children.append(node)
            self.doc.counts["paragraphs"] += 1
            self.note_root_block(frame)
        elif kind == "heading":
            node = frame.pending_node
            node.units = scan_inline(segments, self.doc, False)
            node.plain = plain_text(node.units)
            frame.node.children.append(node)
            self.doc.counts["headings"] += 1
            self.note_root_block(frame)
        elif kind == "item":
            node = frame.node
            node.units = scan_inline(segments, self.doc, True)

    def note_root_block(self, frame):
        if frame.kind == "root":
            self.root_blocks += 1

    def text_line(self, i, line, col0):
        frame = self.stack[-1]
        stripped = line.lstrip(" ")
        lineno = i + 1
        if frame.kind == "table":
            self.table_row(frame, lineno, line)
            return i + 1
        if frame.kind in ("ul", "ol"):
            raise self.err(lineno, col0, "text-not-allowed")
        if frame.kind == "doc":
            self.meta_line(lineno, line, col0)
            return i + 1
        if frame.kind == "fig":
            frame.segments.append((lineno, col0, stripped))
            return i + 1
        if frame.pending_kind is not None:
            frame.segments.append((lineno, col0, stripped))
            return i + 1
        frame.pending_kind = "para"
        frame.segments = [(lineno, col0, stripped)]
        return i + 1

    # -- @doc metadata ----------------------------------------------------

    def meta_line(self, lineno, line, col0):
        pos = 0
        while pos < len(line) and line[pos] in " \t":
            pos += 1
        start = pos
        while pos < len(line) and (
            ("a" <= line[pos] <= "z") or ("0" <= line[pos] <= "9") or line[pos] == "-"
        ):
            pos += 1
        key = line[start:pos]
        while pos < len(line) and line[pos] in " \t":
            pos += 1
        if not key or pos >= len(line) or line[pos] != "=":
            raise self.err(lineno, col0, "bad-syntax")
        value = line[pos + 1:].strip(" \t")
        node = self.stack[-1].node
        if key not in ("title", "author", "date"):
            raise self.err(lineno, start + 1, "unknown-meta")
        if key in node.seen:
            raise self.err(lineno, start + 1, "duplicate-meta")
        node.seen[key] = True
        self.doc.meta[key] = value

    # -- tables -----------------------------------------------------------

    def split_row(self, text):
        """Split a row into cell slices; a backslash consumes the next char."""
        cells = []
        start = 0
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\\":
                i += 2
                continue
            if ch == "|":
                cells.append((start, i))
                start = i + 1
            i += 1
        cells.append((start, len(text)))
        return cells

    def table_row(self, frame, lineno, line):
        node = frame.node
        spans = self.split_row(line)
        if len(spans) != node.cols:
            raise self.err(lineno, 1, "cell-count")
        cells = []
        for lo, hi in spans:
            text = line[lo:hi]
            cells.append(scan_inline([(lineno, lo + 1, text)], self.doc, False))
        node.elements.append(Node("row", cells=cells))

    # -- directives -------------------------------------------------------

    def directive(self, i, line, col0):
        lineno = i + 1
        stripped = line.lstrip(" ")
        end = 0
        while end < len(stripped) and stripped[end] != " ":
            end += 1
        token = stripped[:end]
        name = token
        starred = False
        if token.endswith("*") and token[:-1] in ("@h1", "@h2", "@h3", "@h4"):
            name = token[:-1]
            starred = True
        if name not in BLOCK_NAMES:
            raise self.err(lineno, col0, "unknown-block")
        rest_col = col0 + end
        rest = stripped[end:]
        if name in INLINE_DIRECTIVES:
            return self.inline_directive(i, name, starred, lineno, rest_col, rest)
        attrs = self.parse_attrs(name, lineno, rest_col, rest)
        return self.block_directive(i, name, lineno, col0, attrs)

    def parse_attrs(self, name, lineno, col, text):
        """Parse `name=value` attributes; returns {name: (value, col)}.

        The dictionary preserves source order so that value checks can run
        left to right as the error ordering requires.
        """
        allowed = ATTRS[name]
        out = {}
        pos = 0
        while pos < len(text):
            if text[pos] == " ":
                pos += 1
                col += 1
                continue
            nstart = pos
            ncol = col
            while pos < len(text) and text[pos] in NAME_CHARS:
                pos += 1
                col += 1
            attr = text[nstart:pos]
            if not attr or pos >= len(text) or text[pos] != "=":
                raise self.err(lineno, ncol, "bad-attribute")
            if attr not in allowed:
                raise self.err(lineno, ncol, "bad-attribute")
            if attr in out:
                raise self.err(lineno, ncol, "bad-attribute")
            pos += 1
            col += 1
            vcol = col
            if pos < len(text) and text[pos] == '"':
                close = text.find('"', pos + 1)
                if close < 0:
                    raise self.err(lineno, vcol, "bad-attribute-value")
                value = text[pos + 1:close]
                col += close - pos + 1
                pos = close + 1
            else:
                vstart = pos
                while pos < len(text) and text[pos] in BARE_CHARS:
                    pos += 1
                    col += 1
                value = text[vstart:pos]
                if not value:
                    raise self.err(lineno, vcol, "bad-attribute-value")
            if pos < len(text) and text[pos] != " ":
                raise self.err(lineno, vcol, "bad-attribute-value")
            out[attr] = (value, vcol)
        for required in REQUIRED.get(name, []):
            if required not in out:
                raise self.err(lineno, self.directive_col(lineno), "missing-attribute")
        return out

    def directive_col(self, lineno):
        line = self.lines[lineno - 1]
        return len(line) - len(line.lstrip(" ")) + 1

    def validate_attrs(self, attrs, lineno, validators):
        """Run each attribute's value check in source order."""
        out = {}
        for key, (value, col) in attrs.items():
            parsed = validators[key](value)
            if parsed is None:
                raise self.err(lineno, col, "bad-attribute-value")
            out[key] = parsed
        return out

    @staticmethod
    def length_check(low=0, high=None):
        def check(value):
            parsed = parse_length(value)
            if parsed is None or parsed < low or (high is not None and parsed > high):
                return None
            return parsed
        return check

    @staticmethod
    def integer_check(low, high):
        def check(value):
            parsed = parse_integer(value)
            if parsed is None or parsed < low or parsed > high:
                return None
            return parsed
        return check

    @staticmethod
    def enum_check(choices):
        def check(value):
            return value if value in choices else None
        return check

    @staticmethod
    def letters_check(allowed):
        def check(value):
            if not value or any(ch not in allowed for ch in value):
                return None
            return value
        return check

    # -- the inline-text directives ---------------------------------------

    def inline_directive(self, i, name, starred, lineno, rest_col, rest):
        frame = self.stack[-1]
        if name == "@li":
            holder = frame
            if frame.kind == "item":
                self.close_block(lineno, 1)
                holder = self.stack[-1]
            if holder.kind not in ("ul", "ol"):
                raise self.err(lineno, self.directive_col(lineno), "block-not-allowed")
            number = holder.node.start + len(holder.node.children)
            node = Node("item", units=[], number=number)
            holder.node.children.append(node)
            item = Frame("item", node, implicit=True, at=lineno)
            self.stack.append(item)
            item.pending_kind = "item"
            item.segments = [(lineno, rest_col, rest)]
            return i + 1
        if frame.kind in ("ul", "ol", "table", "doc", "fig"):
            raise self.err(lineno, self.directive_col(lineno), "block-not-allowed")
        level = int(name[2])
        node = Node("heading", level=level, starred=starred, units=[], plain="")
        frame.pending_kind = "heading"
        frame.pending_node = node
        frame.segments = [(lineno, rest_col, rest)]
        # A heading takes no continuation lines: its text is this line alone.
        self.flush_inline()
        return i + 1

    # -- the block directives ---------------------------------------------

    def block_directive(self, i, name, lineno, col0, attrs):
        frame = self.stack[-1]
        lines = self.lines
        if name == "@end":
            if len(self.stack) == 1:
                raise self.err(lineno, col0, "unexpected-end")
            while self.stack[-1].implicit:
                self.close_block(lineno, col0)
            self.close_block(lineno, col0)
            return i + 1
        if name == "@hrule":
            if frame.kind != "table":
                raise self.err(lineno, col0, "block-not-allowed")
            frame.node.elements.append(Node("hrule"))
            return i + 1
        if frame.kind in ("ul", "ol", "table", "doc", "fig"):
            raise self.err(lineno, col0, "block-not-allowed")
        if name == "@doc":
            if self.seen_doc or self.seen_toc or self.root_blocks > 0 or frame.kind != "root":
                raise self.err(lineno, col0, "block-not-allowed")
            self.seen_doc = True
            node = Node("doc", seen={})
            self.stack.append(Frame("doc", node, at=lineno))
            return i + 1
        if name == "@toc":
            if self.seen_toc:
                raise self.err(lineno, col0, "duplicate-toc")
            if self.root_blocks > 0 or frame.kind != "root":
                raise self.err(lineno, col0, "block-not-allowed")
            self.seen_toc = True
            self.doc.has_toc = True
            if "title" in attrs:
                self.doc.toc_title = attrs["title"][0]
            return i + 1
        if name == "@q":
            node = Node("quote")
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.stack.append(Frame("quote", node, at=lineno))
            return i + 1
        if name == "@block":
            values = self.validate_attrs(attrs, lineno, {
                "align": self.enum_check(ALIGNS),
                "indent": self.length_check(0),
                "right-indent": self.length_check(0),
                "font": self.enum_check(FAMILIES),
                "size": self.length_check(1000, 200000),
                "leading": self.length_check(1000),
            })
            node = Node(
                "group",
                align=values.get("align"),
                indent=values.get("indent"),
                right_indent=values.get("right-indent"),
                font=values.get("font"),
                size=values.get("size"),
                leading=values.get("leading"),
            )
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.stack.append(Frame("group", node, at=lineno))
            return i + 1
        if name in ("@ul", "@ol"):
            values = self.validate_attrs(attrs, lineno, {
                "start": self.integer_check(1, 100000),
            })
            start = values.get("start", 1)
            node = Node("list", ordered=(name == "@ol"), start=start)
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.stack.append(Frame("ol" if name == "@ol" else "ul", node, at=lineno))
            return i + 1
        if name == "@table":
            values = self.validate_attrs(attrs, lineno, {
                "cols": self.integer_check(1, 20),
                "align": self.letters_check("lrc"),
            })
            cols = values["cols"]
            align = values.get("align", "l" * cols)
            if len(align) != cols:
                raise self.err(lineno, attrs["align"][1], "bad-attribute-value")
            node = Node("table", cols=cols, align=align, elements=[])
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.doc.counts["tables"] += 1
            self.stack.append(Frame("table", node, at=lineno))
            return i + 1
        if name == "@pre":
            node = Node("pre", lines=[])
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.stack.append(Frame("pre", node, at=lineno))
            return i + 1
        if name == "@fig":
            values = self.validate_attrs(attrs, lineno, {
                "height": self.length_check(0),
                "width": self.length_check(0),
            })
            height = values["height"]
            width = values.get("width")
            index = len(self.doc.figures) + 1
            node = Node("figure", height=height, width=width, index=index, units=[])
            frame.node.children.append(node)
            self.note_root_block(frame)
            self.doc.figures.append(node)
            self.doc.counts["figures"] += 1
            self.stack.append(Frame("fig", node, at=lineno))
            return i + 1
        if name == "@rule":
            frame.node.children.append(Node("rule"))
            self.note_root_block(frame)
            return i + 1
        if name == "@vspace":
            values = self.validate_attrs(attrs, lineno, {
                "height": self.length_check(0),
            })
            frame.node.children.append(Node("vspace", height=values["height"]))
            self.note_root_block(frame)
            return i + 1
        if name == "@newpage":
            frame.node.children.append(Node("newpage"))
            self.note_root_block(frame)
            return i + 1
        raise self.err(lineno, col0, "unknown-block")

    def close_block(self, lineno, col):
        frame = self.stack.pop()
        if frame.kind == "fig":
            frame.node.units = scan_inline(frame.segments, self.doc, False)
        _ = (lineno, col)
