"""The settings.cfg parser and the 126-key settings table."""

from metrics import fdiv

ALIGNS = ["justify", "left", "right", "center"]
FAMILIES = ["serif", "sans", "mono"]
PATTERN_NAMES = ["english", "minimal"]
PLACEHOLDERS = ["page", "pages", "title", "author", "date", "chapter", "section"]

UNITS = {"pt": 1000, "mm": 2835, "cm": 28350, "in": 72000, "pc": 12000}


class CodexaError(Exception):
    """A reportable input error: one file, line, column and code."""

    def __init__(self, filename, line, col, code):
        Exception.__init__(self, code)
        self.filename = filename
        self.line = line
        self.col = col
        self.code = code

    def format(self):
        return "%s:%d:%d: %s" % (self.filename, self.line, self.col, self.code)


# Each entry is (name, type, default, range).  `default` is either a literal
# value, the string "@<key>" meaning "whatever <key> resolved to", or the
# string "@derived" for the two keys computed from the page geometry.
# `range` is None, ("ge", lo) or ("in", lo, hi); text keys use ("leader",) and
# ("noph",) for the two extra restrictions the spec places on them.
TABLE = [
    ("page-width", "length", 612000, ("ge", 36000)),
    ("page-height", "length", 792000, ("ge", 36000)),
    ("margin-top", "length", 72000, ("ge", 0)),
    ("margin-bottom", "length", 72000, ("ge", 0)),
    ("margin-left", "length", 72000, ("ge", 0)),
    ("margin-right", "length", 72000, ("ge", 0)),
    ("header-baseline", "length", 36000, ("ge", 0)),
    ("footer-baseline", "length", "@derived", ("ge", 0)),
    ("page-start", "integer", 1, ("in", 1, 3000)),

    ("body-font", "family", "serif", None),
    ("body-size", "length", 10000, ("in", 1000, 200000)),
    ("leading", "length", 12000, ("ge", 1000)),
    ("line-skip", "length", 1000, ("ge", 0)),
    ("align", "enum", "justify", None),
    ("par-indent", "length", 18000, ("ge", 0)),
    ("par-space", "length", 0, ("ge", 0)),

    ("tolerance", "integer", 1000, ("in", 0, 10000)),
    ("line-penalty", "integer", 10, ("in", 0, 10000)),
    ("hyphen-penalty", "integer", 50, ("in", -9999, 9999)),
    ("ex-hyphen-penalty", "integer", 50, ("in", -9999, 9999)),
    ("adj-demerits", "integer", 10000, ("in", 0, 1000000)),
    ("double-hyphen-demerits", "integer", 10000, ("in", 0, 1000000)),
    ("final-hyphen-demerits", "integer", 5000, ("in", 0, 1000000)),
    ("ragged-stretch", "integer", 3, ("in", 0, 100)),
    ("hyphenate", "boolean", True, None),
    ("hyphen-patterns", "patterns", "english", None),

    ("heading-font", "family", "sans", None),
    ("heading-bold", "boolean", True, None),
    ("heading-italic", "boolean", False, None),
    ("heading-align", "enum", "left", None),
    ("heading-number", "boolean", True, None),
    ("heading-number-gap", "length", 6000, ("ge", 0)),
    ("h1-newpage", "boolean", False, None),
    ("h1-size", "length", 20000, ("in", 1000, 200000)),
    ("h2-size", "length", 14000, ("in", 1000, 200000)),
    ("h3-size", "length", 12000, ("in", 1000, 200000)),
    ("h4-size", "length", 11000, ("in", 1000, 200000)),
    ("h1-leading", "length", 24000, ("ge", 1000)),
    ("h2-leading", "length", 17000, ("ge", 1000)),
    ("h3-leading", "length", 14000, ("ge", 1000)),
    ("h4-leading", "length", 13000, ("ge", 1000)),
    ("h1-space-before", "length", 18000, ("ge", 0)),
    ("h2-space-before", "length", 14000, ("ge", 0)),
    ("h3-space-before", "length", 12000, ("ge", 0)),
    ("h4-space-before", "length", 11000, ("ge", 0)),
    ("h1-space-after", "length", 9000, ("ge", 0)),
    ("h2-space-after", "length", 7000, ("ge", 0)),
    ("h3-space-after", "length", 6000, ("ge", 0)),
    ("h4-space-after", "length", 5000, ("ge", 0)),

    ("list-indent", "length", 18000, ("ge", 0)),
    ("list-marker-gap", "length", 4000, ("ge", 0)),
    ("list-space", "length", 6000, ("ge", 0)),
    ("list-item-space", "length", 0, ("ge", 0)),
    ("quote-indent", "length", 18000, ("ge", 0)),
    ("quote-space", "length", 6000, ("ge", 0)),
    ("pre-font", "family", "mono", None),
    ("pre-size", "length", 9000, ("in", 1000, 200000)),
    ("pre-leading", "length", 11000, ("ge", 1000)),
    ("pre-indent", "length", 0, ("ge", 0)),
    ("pre-space", "length", 6000, ("ge", 0)),

    ("table-col-gap", "length", 8000, ("ge", 0)),
    ("table-row-space", "length", 2000, ("ge", 0)),
    ("table-rule-space", "length", 2000, ("ge", 0)),
    ("table-rule-thickness", "length", 400, ("ge", 1)),
    ("table-space", "length", 6000, ("ge", 0)),
    ("table-leading", "length", 12000, ("ge", 1000)),
    ("rule-thickness", "length", 500, ("ge", 1)),
    ("rule-space", "length", 6000, ("ge", 0)),

    ("footnote-font", "family", "serif", None),
    ("footnote-size", "length", 8000, ("in", 1000, 200000)),
    ("footnote-leading", "length", 10000, ("ge", 1000)),
    ("footnote-indent", "length", 10000, ("ge", 0)),
    ("footnote-mark-gap", "length", 2000, ("ge", 0)),
    ("footnote-mark-size", "length", 6000, ("in", 1000, 200000)),
    ("footnote-mark-raise", "length", 2000, ("ge", 0)),
    ("footnote-item-space", "length", 2000, ("ge", 0)),
    ("footnote-rule-width", "length", 120000, ("ge", 0)),
    ("footnote-rule-thickness", "length", 400, ("ge", 1)),
    ("footnote-space-before", "length", 6000, ("ge", 0)),
    ("footnote-space-after", "length", 3000, ("ge", 0)),
    ("footnote-min-split", "integer", 1, ("in", 1, 100)),
    ("footnote-max-height", "length", "@derived", ("ge", 1000)),
    ("mark-size", "length", 7000, ("in", 1000, 200000)),
    ("mark-raise", "length", 3000, ("ge", 0)),

    ("figure-width", "length", 0, ("ge", 0)),
    ("figure-frame", "boolean", True, None),
    ("figure-caption-font", "family", "serif", None),
    ("figure-caption-size", "length", 9000, ("in", 1000, 200000)),
    ("figure-caption-leading", "length", 11000, ("ge", 1000)),
    ("figure-caption-align", "enum", "center", None),
    ("figure-caption-space", "length", 4000, ("ge", 0)),
    ("figure-caption-prefix", "text", "Figure", ("noph",)),
    ("figure-caption-gap", "length", 4000, ("ge", 0)),
    ("float-space-after", "length", 12000, ("ge", 0)),
    ("float-min-body", "length", 24000, ("ge", 0)),

    ("widows", "integer", 2, ("in", 1, 20)),
    ("orphans", "integer", 2, ("in", 1, 20)),
    ("keep-with-next", "boolean", True, None),

    ("toc-depth", "integer", 2, ("in", 0, 4)),
    ("toc-font", "family", "serif", None),
    ("toc-size", "length", 10000, ("in", 1000, 200000)),
    ("toc-leading", "length", 14000, ("ge", 1000)),
    ("toc-indent", "length", 18000, ("ge", 0)),
    ("toc-number-gap", "length", 6000, ("ge", 0)),
    ("toc-reserve", "length", 30000, ("ge", 0)),
    ("toc-leader", "text", ".", ("leader",)),
    ("toc-leader-gap", "length", 3000, ("ge", 0)),
    ("toc-entry-space", "length", 0, ("ge", 0)),
    ("toc-title", "text", "Contents", ("noph",)),
    ("toc-title-font", "family", "sans", None),
    ("toc-title-size", "length", 20000, ("in", 1000, 200000)),
    ("toc-title-space-after", "length", 12000, ("ge", 0)),

    ("header-font", "family", "sans", None),
    ("header-size", "length", 9000, ("in", 1000, 200000)),
    ("header-left", "text", "", None),
    ("header-center", "text", "", None),
    ("header-right", "text", "", None),
    ("footer-left", "text", "", None),
    ("footer-center", "text", "", None),
    ("footer-right", "text", "", None),
    ("header-left-even", "text", "@header-left", None),
    ("header-center-even", "text", "@header-center", None),
    ("header-right-even", "text", "@header-right", None),
    ("footer-left-even", "text", "@footer-left", None),
    ("footer-center-even", "text", "@footer-center", None),
    ("footer-right-even", "text", "@footer-right", None),
]

BY_NAME = {entry[0]: entry for entry in TABLE}

TYPE_ERROR = {
    "length": "bad-length",
    "integer": "bad-integer",
    "boolean": "bad-boolean",
    "enum": "bad-enum",
    "family": "unknown-font",
    "patterns": "unknown-patterns",
}

GEOMETRY_KEYS = [
    "page-width", "page-height",
    "margin-top", "margin-bottom", "margin-left", "margin-right",
]


def parse_length(text):
    """Return the millipoint value of a length literal, or None if malformed."""
    rest = text
    negative = False
    if rest.startswith("-"):
        negative = True
        rest = rest[1:]
    digits = 0
    while digits < len(rest) and rest[digits].isdigit() and rest[digits].isascii():
        digits += 1
    if digits == 0:
        return None
    whole = int(rest[:digits])
    rest = rest[digits:]
    frac = 0
    k = 0
    if rest.startswith("."):
        rest = rest[1:]
        fdigits = 0
        while fdigits < len(rest) and rest[fdigits].isdigit() and rest[fdigits].isascii():
            fdigits += 1
        if fdigits < 1 or fdigits > 3:
            return None
        frac = int(rest[:fdigits])
        k = fdigits
        rest = rest[fdigits:]
    unit_mp = 1
    if rest:
        if rest not in UNITS:
            return None
        unit_mp = UNITS[rest]
    value = fdiv((whole * (10 ** k) + frac) * unit_mp, 10 ** k)
    return -value if negative else value


def parse_integer(text):
    """Return the value of an integer literal, or None if malformed."""
    rest = text
    negative = False
    if rest.startswith("-"):
        negative = True
        rest = rest[1:]
    if not rest or not all(ch.isdigit() and ch.isascii() for ch in rest):
        return None
    value = int(rest)
    return -value if negative else value


def parse_text(value, filename, lineno, vcol):
    """Parse a text value into a list of ('lit', s) and ('ph', name) pieces."""
    pieces = []
    buf = []
    i = 0
    n = len(value)
    while i < n:
        ch = value[i]
        if ch == "\\":
            if i + 1 < n and value[i + 1] in "{}\\":
                buf.append(value[i + 1])
                i += 2
                continue
            raise CodexaError(filename, lineno, vcol + i, "bad-escape")
        if ch == "{":
            close = value.find("}", i + 1)
            name = value[i + 1:close] if close >= 0 else None
            if name is None or name not in PLACEHOLDERS:
                raise CodexaError(filename, lineno, vcol + i, "unknown-placeholder")
            if buf:
                pieces.append(("lit", "".join(buf)))
                buf = []
            pieces.append(("ph", name))
            i = close + 1
            continue
        if ch == "}":
            raise CodexaError(filename, lineno, vcol + i, "stray-brace")
        buf.append(ch)
        i += 1
    if buf:
        pieces.append(("lit", "".join(buf)))
    return pieces


def text_is_literal(pieces):
    return all(kind == "lit" for kind, _ in pieces)


def text_literal(pieces):
    return "".join(body for kind, body in pieces if kind == "lit")


class Settings:
    """Resolved settings plus the derived page geometry."""

    def __init__(self):
        self.values = {}
        self.alias = {}
        for name, kind, default, _range in TABLE:
            if kind == "text":
                if isinstance(default, str) and default.startswith("@"):
                    self.alias[name] = default[1:]
                    self.values[name] = []
                else:
                    self.values[name] = [("lit", default)] if default else []
            else:
                self.values[name] = default
        self.assigned = {}

    def __getitem__(self, key):
        return self.values[key]

    def text(self, key):
        """The literal text of a text setting that holds no placeholder."""
        return text_literal(self.values[key])

    def resolve_geometry(self):
        if self.values["footer-baseline"] == "@derived":
            self.values["footer-baseline"] = self.values["page-height"] - 36000
        self.page_width = self.values["page-width"]
        self.page_height = self.values["page-height"]
        self.body_x = self.values["margin-left"]
        self.body_y = self.values["margin-top"]
        self.body_width = self.page_width - self.values["margin-left"] - self.values["margin-right"]
        self.body_height = self.page_height - self.values["margin-top"] - self.values["margin-bottom"]
        self.body_bottom = self.body_y + self.body_height
        if self.values["footnote-max-height"] == "@derived":
            self.values["footnote-max-height"] = fdiv(self.body_height, 2)
        for name, source in self.alias.items():
            if name not in self.assigned:
                self.values[name] = self.values[source]


def check_value_range(name, kind, value, spec, filename, lineno, vcol, pieces=None):
    if kind == "text":
        if spec == ("noph",):
            if pieces is not None and not text_is_literal(pieces):
                raise CodexaError(filename, lineno, vcol, "bad-value")
        elif spec == ("leader",):
            if pieces is not None and not text_is_literal(pieces):
                raise CodexaError(filename, lineno, vcol, "bad-value")
            text = value
            if len(text) < 1 or len(text) > 8 or " " in text:
                raise CodexaError(filename, lineno, vcol, "bad-value")
        return
    if spec is None:
        return
    if spec[0] == "ge":
        if value < spec[1]:
            raise CodexaError(filename, lineno, vcol, "bad-value")
    elif spec[0] == "in":
        if value < spec[1] or value > spec[2]:
            raise CodexaError(filename, lineno, vcol, "bad-value")


def parse_settings(text, filename="settings.cfg"):
    """Validate settings.cfg and return the resolved Settings object."""
    settings = Settings()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    seen = {}
    last_geometry = None
    for index, line in enumerate(lines):
        lineno = index + 1
        pos = 0
        while pos < len(line) and line[pos] in " \t":
            pos += 1
        if pos >= len(line):
            continue
        if line[pos] == "#":
            continue
        start = pos
        key_end = pos
        while key_end < len(line) and (
            ("a" <= line[key_end] <= "z") or ("0" <= line[key_end] <= "9") or line[key_end] == "-"
        ):
            key_end += 1
        if key_end == start:
            raise CodexaError(filename, lineno, start + 1, "bad-syntax")
        key = line[start:key_end]
        pos = key_end
        while pos < len(line) and line[pos] in " \t":
            pos += 1
        if pos >= len(line) or line[pos] != "=":
            raise CodexaError(filename, lineno, start + 1, "bad-syntax")
        pos += 1
        vstart = pos
        while vstart < len(line) and line[vstart] in " \t":
            vstart += 1
        value_text = line[vstart:].rstrip(" \t")
        if not value_text:
            vstart = len(line)
        vcol = vstart + 1
        entry = BY_NAME.get(key)
        if entry is None:
            raise CodexaError(filename, lineno, start + 1, "unknown-setting")
        if key in seen:
            raise CodexaError(filename, lineno, start + 1, "duplicate-setting")
        seen[key] = True
        _name, kind, _default, spec = entry
        pieces = None
        if kind == "length":
            parsed = parse_length(value_text)
            if parsed is None:
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
        elif kind == "integer":
            parsed = parse_integer(value_text)
            if parsed is None:
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
        elif kind == "boolean":
            if value_text not in ("on", "off"):
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
            parsed = value_text == "on"
        elif kind == "enum":
            if value_text not in ALIGNS:
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
            parsed = value_text
        elif kind == "family":
            if value_text not in FAMILIES:
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
            parsed = value_text
        elif kind == "patterns":
            if value_text not in PATTERN_NAMES:
                raise CodexaError(filename, lineno, vcol, TYPE_ERROR[kind])
            parsed = value_text
        else:
            pieces = parse_text(value_text, filename, lineno, vcol)
            parsed = pieces
        check_value_range(
            key, kind, text_literal(pieces) if pieces is not None else parsed,
            spec, filename, lineno, vcol, pieces,
        )
        settings.values[key] = parsed
        settings.assigned[key] = (lineno, vcol)
        if key in GEOMETRY_KEYS:
            last_geometry = (lineno, vcol)
    settings.resolve_geometry()
    if settings.body_width < 36000 or settings.body_height < 36000:
        if last_geometry is None:
            raise CodexaError(filename, 0, 0, "bad-value")
        raise CodexaError(filename, last_geometry[0], last_geometry[1], "bad-value")
    return settings


def default_settings():
    settings = Settings()
    settings.resolve_geometry()
    return settings
