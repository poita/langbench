"""The ``settings.cfg`` parser and the table of layout settings."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .errors import CodexaError
from .units import parse_integer, parse_length

PT = 1000
FILE = "settings.cfg"

PLACEHOLDERS = ("page", "pages", "title", "author", "date", "chapter", "section")
ALIGNS = ("justify", "left", "right", "center")

# A text value is a list of parts: ("lit", str) or ("ph", name).
Text = list


def _spec(kind: str, default, lo=None, hi=None):
    return (kind, default, lo, hi)


def _len(default, lo=0, hi=None):
    return _spec("length", default, lo, hi)


def _int(default, lo, hi):
    return _spec("integer", default, lo, hi)


def _bool(default):
    return _spec("boolean", default)


def _enum(default):
    return _spec("enum", default)


def _fam(default):
    return _spec("family", default)


def _text(default):
    return _spec("text", [("lit", default)] if default else [])


_FONT = (1000, 200000)

#: key -> (kind, default, lo, hi).  Derived defaults are ``None`` here and
#: filled in after all assignments have been read.
SPECS: dict[str, tuple] = {
    # page geometry
    "page-width": _len(612 * PT, 36000),
    "page-height": _len(792 * PT, 36000),
    "margin-top": _len(72 * PT),
    "margin-bottom": _len(72 * PT),
    "margin-left": _len(72 * PT),
    "margin-right": _len(72 * PT),
    "header-baseline": _len(36 * PT),
    "footer-baseline": _len(None),
    "page-start": _int(1, 1, 3000),
    # body text
    "body-font": _fam("serif"),
    "body-size": _len(10 * PT, *_FONT),
    "leading": _len(12 * PT, 1000),
    "line-skip": _len(1 * PT),
    "align": _enum("justify"),
    "par-indent": _len(18 * PT),
    "par-space": _len(0),
    # line breaking
    "tolerance": _int(1000, 0, 10000),
    "line-penalty": _int(10, 0, 10000),
    "hyphen-penalty": _int(50, -9999, 9999),
    "ex-hyphen-penalty": _int(50, -9999, 9999),
    "adj-demerits": _int(10000, 0, 1000000),
    "double-hyphen-demerits": _int(10000, 0, 1000000),
    "final-hyphen-demerits": _int(5000, 0, 1000000),
    "ragged-stretch": _int(3, 0, 100),
    "hyphenate": _bool(True),
    "hyphen-patterns": _spec("patterns", "english"),
    # headings
    "heading-font": _fam("sans"),
    "heading-bold": _bool(True),
    "heading-italic": _bool(False),
    "heading-align": _enum("left"),
    "heading-number": _bool(True),
    "heading-number-gap": _len(6 * PT),
    "h1-newpage": _bool(False),
    "h1-size": _len(20 * PT, *_FONT),
    "h2-size": _len(14 * PT, *_FONT),
    "h3-size": _len(12 * PT, *_FONT),
    "h4-size": _len(11 * PT, *_FONT),
    "h1-leading": _len(24 * PT, 1000),
    "h2-leading": _len(17 * PT, 1000),
    "h3-leading": _len(14 * PT, 1000),
    "h4-leading": _len(13 * PT, 1000),
    "h1-space-before": _len(18 * PT),
    "h2-space-before": _len(14 * PT),
    "h3-space-before": _len(12 * PT),
    "h4-space-before": _len(11 * PT),
    "h1-space-after": _len(9 * PT),
    "h2-space-after": _len(7 * PT),
    "h3-space-after": _len(6 * PT),
    "h4-space-after": _len(5 * PT),
    # lists, quotes, preformatted
    "list-indent": _len(18 * PT),
    "list-marker-gap": _len(4 * PT),
    "list-space": _len(6 * PT),
    "list-item-space": _len(0),
    "quote-indent": _len(18 * PT),
    "quote-space": _len(6 * PT),
    "pre-font": _fam("mono"),
    "pre-size": _len(9 * PT, *_FONT),
    "pre-leading": _len(11 * PT, 1000),
    "pre-indent": _len(0),
    "pre-space": _len(6 * PT),
    # tables and rules
    "table-col-gap": _len(8 * PT),
    "table-row-space": _len(2 * PT),
    "table-rule-space": _len(2 * PT),
    "table-rule-thickness": _len(400, 1),
    "table-space": _len(6 * PT),
    "table-leading": _len(12 * PT, 1000),
    "rule-thickness": _len(500, 1),
    "rule-space": _len(6 * PT),
    # footnotes
    "footnote-font": _fam("serif"),
    "footnote-size": _len(8 * PT, *_FONT),
    "footnote-leading": _len(10 * PT, 1000),
    "footnote-indent": _len(10 * PT),
    "footnote-mark-gap": _len(2 * PT),
    "footnote-mark-size": _len(6 * PT, *_FONT),
    "footnote-mark-raise": _len(2 * PT),
    "footnote-item-space": _len(2 * PT),
    "footnote-rule-width": _len(120 * PT),
    "footnote-rule-thickness": _len(400, 1),
    "footnote-space-before": _len(6 * PT),
    "footnote-space-after": _len(3 * PT),
    "footnote-min-split": _int(1, 1, 100),
    "footnote-max-height": _len(None, 1000),
    "mark-size": _len(7 * PT, *_FONT),
    "mark-raise": _len(3 * PT),
    # figures
    "figure-width": _len(0),
    "figure-frame": _bool(True),
    "figure-caption-font": _fam("serif"),
    "figure-caption-size": _len(9 * PT, *_FONT),
    "figure-caption-leading": _len(11 * PT, 1000),
    "figure-caption-align": _enum("center"),
    "figure-caption-space": _len(4 * PT),
    "figure-caption-prefix": _text("Figure"),
    "figure-caption-gap": _len(4 * PT),
    "float-space-after": _len(12 * PT),
    "float-min-body": _len(24 * PT),
    # page breaking
    "widows": _int(2, 1, 20),
    "orphans": _int(2, 1, 20),
    "keep-with-next": _bool(True),
    # table of contents
    "toc-depth": _int(2, 0, 4),
    "toc-font": _fam("serif"),
    "toc-size": _len(10 * PT, *_FONT),
    "toc-leading": _len(14 * PT, 1000),
    "toc-indent": _len(18 * PT),
    "toc-number-gap": _len(6 * PT),
    "toc-reserve": _len(30 * PT),
    "toc-leader": _text("."),
    "toc-leader-gap": _len(3 * PT),
    "toc-entry-space": _len(0),
    "toc-title": _text("Contents"),
    "toc-title-font": _fam("sans"),
    "toc-title-size": _len(20 * PT, *_FONT),
    "toc-title-space-after": _len(12 * PT),
    # running headers and footers
    "header-font": _fam("sans"),
    "header-size": _len(9 * PT, *_FONT),
}

SLOTS = ("header-left", "header-center", "header-right",
         "footer-left", "footer-center", "footer-right")
for _s in SLOTS:
    SPECS[_s] = _text("")
for _s in SLOTS:
    SPECS[_s + "-even"] = _text("")

#: Keys that take a text value that may not contain placeholders.
_NO_PLACEHOLDERS = ("figure-caption-prefix", "toc-leader", "toc-title")

_GEOMETRY_KEYS = ("page-width", "page-height", "margin-top", "margin-bottom",
                  "margin-left", "margin-right")

_ASSIGN_RE = re.compile(r"[ \t]*([a-z0-9-]+)[ \t]*=(.*)\Z")


class Settings:
    """All layout settings as attributes (``body-size`` -> ``body_size``).

    Lengths are millipoints; ``text`` settings are lists of
    ``("lit", str)`` / ``("ph", name)`` parts.  Derived geometry is available
    as ``body_x``, ``body_y``, ``body_width``, ``body_height``, ``body_bottom``.
    """

    def __init__(self) -> None:
        for key, (_kind, default, _lo, _hi) in SPECS.items():
            setattr(self, key.replace("-", "_"), default)
        self.finish(())

    def finish(self, assigned) -> None:
        """Resolve the settings whose defaults depend on other settings."""
        if "footer-baseline" not in assigned:
            self.footer_baseline = self.page_height - 36 * PT
        self.body_x = self.margin_left
        self.body_y = self.margin_top
        self.body_width = self.page_width - self.margin_left - self.margin_right
        self.body_height = self.page_height - self.margin_top - self.margin_bottom
        self.body_bottom = self.body_y + self.body_height
        if "footnote-max-height" not in assigned:
            self.footnote_max_height = self.body_height // 2
        for slot in SLOTS:
            if slot + "-even" not in assigned:
                setattr(self, (slot + "-even").replace("-", "_"), getattr(self, slot.replace("-", "_")))


def _scan_text(value: str, base_col: int, line: int) -> Text:
    """Single-scan parse of a *text* value into literal/placeholder parts."""
    parts: Text = []
    lit: list[str] = []
    i, n = 0, len(value)

    def fail(code: str, at: int):
        raise CodexaError(FILE, line, base_col + at, code)

    while i < n:
        c = value[i]
        if c == "\\":
            if i + 1 < n and value[i + 1] in "{}\\":
                lit.append(value[i + 1])
                i += 2
            else:
                fail("bad-escape", i)
        elif c == "{":
            j = value.find("}", i + 1)
            if j < 0 or value[i + 1:j] not in PLACEHOLDERS:
                fail("unknown-placeholder", i)
            if lit:
                parts.append(("lit", "".join(lit)))
                lit = []
            parts.append(("ph", value[i + 1:j]))
            i = j + 1
        elif c == "}":
            fail("stray-brace", i)
        else:
            lit.append(c)
            i += 1
    if lit:
        parts.append(("lit", "".join(lit)))
    return parts


def parse_settings(text: str | None) -> Settings:
    """Parse and validate ``settings.cfg`` contents (``None`` = absent).

    Raises :class:`CodexaError` at the first problem.
    """
    settings = Settings()
    if text is None:
        return settings
    assigned: dict[str, int] = {}
    geometry_pos: tuple[int, int] | None = None
    for lineno, line in enumerate(text.split("\n"), 1):
        start = len(line) - len(line.lstrip(" \t"))
        if start == len(line) or line[start] == "#":
            continue
        m = _ASSIGN_RE.match(line)
        if m is None:
            raise CodexaError(FILE, lineno, start + 1, "bad-syntax")
        key = m.group(1)
        if key not in SPECS:
            raise CodexaError(FILE, lineno, m.start(1) + 1, "unknown-setting")
        if key in assigned:
            raise CodexaError(FILE, lineno, m.start(1) + 1, "duplicate-setting")
        raw = m.group(2)
        value = raw.strip(" \t")
        vcol = m.start(2) + (len(raw) - len(raw.lstrip(" \t"))) + 1
        kind, _default, lo, hi = SPECS[key]
        result = _convert(kind, key, value, vcol, lineno)
        if lo is not None and kind in ("length", "integer"):
            if result < lo or (hi is not None and result > hi):
                raise CodexaError(FILE, lineno, vcol, "bad-value")
        elif kind == "text" and key in _NO_PLACEHOLDERS:
            if any(p[0] == "ph" for p in result):
                raise CodexaError(FILE, lineno, vcol, "bad-value")
            if key == "toc-leader":
                s = "".join(p[1] for p in result)
                if not 1 <= len(s) <= 8 or " " in s:
                    raise CodexaError(FILE, lineno, vcol, "bad-value")
        assigned[key] = lineno
        setattr(settings, key.replace("-", "_"), result)
        if key in _GEOMETRY_KEYS:
            geometry_pos = (lineno, vcol)
    settings.finish(assigned)
    if settings.body_width < 36000 or settings.body_height < 36000:
        line, col = geometry_pos if geometry_pos else (0, 0)
        raise CodexaError(FILE, line, col, "bad-value")
    return settings


def _convert(kind: str, key: str, value: str, vcol: int, line: int):
    def bad(code: str):
        raise CodexaError(FILE, line, vcol, code)

    if kind == "length":
        v = parse_length(value)
        return bad("bad-length") if v is None else v
    if kind == "integer":
        v = parse_integer(value)
        return bad("bad-integer") if v is None else v
    if kind == "boolean":
        if value not in ("on", "off"):
            bad("bad-boolean")
        return value == "on"
    if kind == "enum":
        if value not in ALIGNS:
            bad("bad-enum")
        return value
    if kind == "family":
        if value not in ("serif", "sans", "mono"):
            bad("unknown-font")
        return value
    if kind == "patterns":
        if value not in ("english", "minimal"):
            bad("unknown-patterns")
        return value
    return _scan_text(value, vcol, line)


def text_literal(parts: Text) -> str:
    """The literal string of a text value that has no placeholders."""
    return "".join(p[1] for p in parts)
