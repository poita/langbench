"""A from-scratch JSON parser and compact serializer.

Both follow SPEC.md: the parser accepts RFC 8259 text and builds jq values
(:mod:`jqlite.values`); the serializer prints compact JSON with jq's number
and string formatting.
"""

from __future__ import annotations

import re
from typing import Any

from .errors import JSONDecodeError
from .values import Obj

# --------------------------------------------------------------------------
# String escapes (shared with the filter lexer)

_STRING_BODY = re.compile(r'"((?:[^"\\]+|\\.)*)"', re.S)
_ESCAPE = re.compile(
    r"\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})"
    r"|\\u([0-9a-fA-F]{4})"
    r"|\\(.)",
    re.S,
)
_SIMPLE = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f",
           "n": "\n", "r": "\r", "t": "\t"}


def _unescape_one(m: re.Match) -> str:
    hi, lo, bmp, simple = m.groups()
    if hi is not None:
        return chr(0x10000 + ((int(hi, 16) - 0xD800) << 10) + (int(lo, 16) - 0xDC00))
    if bmp is not None:
        return chr(int(bmp, 16))
    try:
        return _SIMPLE[simple]
    except KeyError:
        raise ValueError(f"invalid escape \\{simple}") from None


def unescape(body: str) -> str:
    """Decode the JSON escapes of a string body (the text between the quotes)."""
    if "\\" not in body:
        return body
    return _ESCAPE.sub(_unescape_one, body)


# --------------------------------------------------------------------------
# Parser

_TOKEN = re.compile(
    r'[ \t\n\r]*(?:'
    r'("[^"\\]*")'                                   # 1: string without escapes
    r'|(-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)'  # 2: number
    r'|([{}\[\],:])'                                 # 3: punctuation
    r'|(true|false|null)'                            # 4: literal
    r'|(")'                                          # 5: string with escapes
    r'|($))'                                         # 6: end of input
)
_WS = re.compile(r"[ \t\n\r]*")
_LITERALS = {"true": True, "false": False, "null": None}


class _Parser:
    __slots__ = ("text", "pos")

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    def error(self, msg: str) -> JSONDecodeError:
        return JSONDecodeError(f"{msg} at offset {self.pos}")

    def string_at(self, start: int) -> str:
        """Parse a string whose opening quote is at ``start`` (slow path)."""
        m = _STRING_BODY.match(self.text, start)
        if m is None:
            self.pos = start
            raise self.error("unterminated string")
        self.pos = m.end()
        try:
            return unescape(m.group(1))
        except ValueError as exc:
            raise self.error(str(exc)) from None

    def value(self) -> Any:
        m = _TOKEN.match(self.text, self.pos)
        if m is None:
            raise self.error("unexpected character")
        g = m.lastindex
        self.pos = m.end()
        if g == 1:
            return m.group(1)[1:-1]
        if g == 2:
            return float(m.group(2))
        if g == 4:
            return _LITERALS[m.group(4)]
        if g == 5:
            return self.string_at(self.pos - 1)
        if g == 3:
            c = m.group(3)
            if c == "[":
                return self.array()
            if c == "{":
                return self.object()
        raise self.error("unexpected token")

    def array(self) -> list:
        text = self.text
        out: list = []
        m = _TOKEN.match(text, self.pos)
        if m is not None and m.lastindex == 3 and m.group(3) == "]":
            self.pos = m.end()
            return out
        while True:
            out.append(self.value())
            m = _TOKEN.match(text, self.pos)
            if m is None or m.lastindex != 3:
                raise self.error("expected ',' or ']'")
            self.pos = m.end()
            c = m.group(3)
            if c == "]":
                return out
            if c != ",":
                raise self.error("expected ',' or ']'")

    def object(self) -> Obj:
        text = self.text
        out = Obj()
        m = _TOKEN.match(text, self.pos)
        if m is not None and m.lastindex == 3 and m.group(3) == "}":
            self.pos = m.end()
            return out
        while True:
            m = _TOKEN.match(text, self.pos)
            if m is None:
                raise self.error("expected object key")
            g = m.lastindex
            self.pos = m.end()
            if g == 1:
                key = m.group(1)[1:-1]
            elif g == 5:
                key = self.string_at(self.pos - 1)
            else:
                raise self.error("expected object key")
            m = _TOKEN.match(text, self.pos)
            if m is None or m.lastindex != 3 or m.group(3) != ":":
                raise self.error("expected ':'")
            self.pos = m.end()
            out[key] = self.value()
            m = _TOKEN.match(text, self.pos)
            if m is None or m.lastindex != 3:
                raise self.error("expected ',' or '}'")
            self.pos = m.end()
            c = m.group(3)
            if c == "}":
                return out
            if c != ",":
                raise self.error("expected ',' or '}'")


def loads(text: str) -> Any:
    """Parse one JSON value (with optional surrounding whitespace).

    Numbers become ``float`` (correctly rounded), objects :class:`Obj`.
    Raises :class:`~jqlite.errors.JSONDecodeError` on malformed input.
    """
    p = _Parser(text)
    v = p.value()
    p.pos = _WS.match(text, p.pos).end()
    if p.pos != len(text):
        raise p.error("trailing characters")
    return v


# --------------------------------------------------------------------------
# Serializer

_NEEDS_ESCAPE = re.compile(r'[\x00-\x1f"\\\x7f]')
_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f",
            "\n": "\\n", "\r": "\\r", "\t": "\\t"}
for _i in range(0x20):
    _ESCAPES.setdefault(chr(_i), "\\u%04x" % _i)
_ESCAPES["\x7f"] = "\\u007f"


def _escape_one(m: re.Match) -> str:
    return _ESCAPES[m.group()]


def dump_string(s: str) -> str:
    """Quote and escape a string as jq does."""
    if _NEEDS_ESCAPE.search(s) is None:
        return '"' + s + '"'
    return '"' + _NEEDS_ESCAPE.sub(_escape_one, s) + '"'


def format_number(x: float) -> str:
    """Integers print without point or exponent, others as the shortest
    round-tripping decimal."""
    if x.is_integer() and -1e17 < x < 1e17:
        return str(int(x))
    return repr(x)


def _dump(v: Any, out: list[str]) -> None:
    t = type(v)
    if t is str:
        out.append(dump_string(v))
    elif t is float:
        out.append(format_number(v))
    elif v is None:
        out.append("null")
    elif t is bool:
        out.append("true" if v else "false")
    elif t is list:
        if not v:
            out.append("[]")
            return
        out.append("[")
        first = True
        for x in v:
            if first:
                first = False
            else:
                out.append(",")
            _dump(x, out)
        out.append("]")
    else:
        if not v:
            out.append("{}")
            return
        out.append("{")
        first = True
        for k, x in v.items():
            if first:
                first = False
            else:
                out.append(",")
            out.append(dump_string(k))
            out.append(":")
            _dump(x, out)
        out.append("}")


def dumps(v: Any) -> str:
    """Serialize a jq value as compact JSON."""
    t = type(v)
    if t is str:
        return dump_string(v)
    if t is float:
        return format_number(v)
    out: list[str] = []
    _dump(v, out)
    return "".join(out)
