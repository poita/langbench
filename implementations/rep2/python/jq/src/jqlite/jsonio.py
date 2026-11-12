"""A from-scratch JSON parser and compact serializer.

The parser is iterative (no recursion limit on nesting) and scans with
precompiled regular expressions.  The serializer produces the compact form
that jq prints with ``-c``.
"""

from __future__ import annotations

import re
from typing import Any

from .errors import JSONDecodeError
from .values import Obj

# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

_TOKEN = re.compile(
    r"""[ \t\n\r]*(?:
        "([^"\\\x00-\x1f]*(?:\\[^\x00-\x1f][^"\\\x00-\x1f]*)*)"   # 1 string body
      | ([\[\]{}:,])                                              # 2 punctuation
      | (-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)    # 3 number
      | (true|false|null)                                         # 4 literal
      | (\Z)                                                      # 5 end of text
    )""",
    re.X,
)
_AFTER_VALUE = re.compile(r"[ \t\n\r]*([,\]}])")
_CLOSE_ARRAY = re.compile(r"[ \t\n\r]*\]")
_CLOSE_OBJECT = re.compile(r"[ \t\n\r]*\}")
_KEY = re.compile(
    r'[ \t\n\r]*"([^"\\\x00-\x1f]*(?:\\[^\x00-\x1f][^"\\\x00-\x1f]*)*)"[ \t\n\r]*:'
)
_TRAILING = re.compile(r"[ \t\n\r]*\Z")

_LITERALS = {"true": True, "false": False, "null": None}

_ESCAPE = re.compile(
    r"\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})"
    r"|\\u([0-9a-fA-F]{4})"
    r"|\\(.)",
    re.S,
)
_SIMPLE_ESCAPES = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
}


def _escape_sub(m: "re.Match[str]") -> str:
    hi, lo, bmp, simple = m.groups()
    if hi is not None:
        return chr(0x10000 + ((int(hi, 16) - 0xD800) << 10) + (int(lo, 16) - 0xDC00))
    if bmp is not None:
        return chr(int(bmp, 16))
    try:
        return _SIMPLE_ESCAPES[simple]
    except KeyError:
        raise JSONDecodeError(f"invalid escape sequence \\{simple}") from None


def unescape(body: str) -> str:
    """Decode the escapes in the body of a JSON string literal."""
    if "\\" not in body:
        return body
    return _ESCAPE.sub(_escape_sub, body)


def _fail(text: str, pos: int, what: str) -> JSONDecodeError:
    line = text.count("\n", 0, pos) + 1
    col = pos - (text.rfind("\n", 0, pos) + 1) + 1
    return JSONDecodeError(f"{what} at line {line}, column {col}")


def loads(text: str) -> Any:
    """Parse a single JSON value from ``text``.

    Objects become :class:`jqlite.values.Obj` (document key order is kept; for
    a repeated key the first position and the last value win), arrays become
    lists, numbers become floats.  Raises :class:`JSONDecodeError` on
    malformed input.
    """
    match = _TOKEN.match
    stack: list = []  # open containers
    keys: list = []  # pending key of each open container; None for arrays
    pos = 0
    while True:
        # ---- read one value (or open a container) ----
        mo = match(text, pos)
        if mo is None:
            raise _fail(text, pos, "Expecting value")
        kind = mo.lastindex
        pos = mo.end()
        if kind == 1:
            value: Any = unescape(mo.group(1))
        elif kind == 3:
            value = float(mo.group(3))
        elif kind == 4:
            value = _LITERALS[mo.group(4)]
        elif kind == 2:
            c = mo.group(2)
            if c == "[":
                m2 = _CLOSE_ARRAY.match(text, pos)
                if m2:
                    pos = m2.end()
                    value = []
                else:
                    stack.append([])
                    keys.append(None)
                    continue
            elif c == "{":
                m2 = _CLOSE_OBJECT.match(text, pos)
                if m2:
                    pos = m2.end()
                    value = Obj()
                else:
                    m3 = _KEY.match(text, pos)
                    if m3 is None:
                        raise _fail(text, pos, "Expecting property name")
                    pos = m3.end()
                    stack.append(Obj())
                    keys.append(unescape(m3.group(1)))
                    continue
            else:
                raise _fail(text, mo.start(2), "Expecting value")
        else:
            raise _fail(text, mo.start(5), "Unexpected end of input")

        # ---- attach the value, closing containers as far as possible ----
        while True:
            if not stack:
                if _TRAILING.match(text, pos) is None:
                    raise _fail(text, pos, "Extra data")
                return value
            top = stack[-1]
            key = keys[-1]
            if key is None:
                top.append(value)
            else:
                top[key] = value
            m2 = _AFTER_VALUE.match(text, pos)
            if m2 is None:
                raise _fail(text, pos, "Expecting ',' or closing bracket")
            c = m2.group(1)
            pos = m2.end()
            if c == ",":
                if key is not None:
                    m3 = _KEY.match(text, pos)
                    if m3 is None:
                        raise _fail(text, pos, "Expecting property name")
                    pos = m3.end()
                    keys[-1] = unescape(m3.group(1))
                break
            if (c == "]") != (key is None):
                raise _fail(text, pos - 1, "Mismatched closing bracket")
            stack.pop()
            keys.pop()
            value = top


# --------------------------------------------------------------------------
# Serialization
# --------------------------------------------------------------------------

_NEEDS_ESCAPE = re.compile(r'[\x00-\x1f"\\\x7f]')
_ESCAPE_TABLE = {chr(i): "\\u%04x" % i for i in range(0x20)}
_ESCAPE_TABLE.update(
    {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
)
_ESCAPE_TABLE["\x7f"] = "\\u007f"


def _escape_char(m: "re.Match[str]") -> str:
    return _ESCAPE_TABLE[m.group()]


def _enc_string(s: str) -> str:
    if _NEEDS_ESCAPE.search(s) is None:
        return '"' + s + '"'
    return '"' + _NEEDS_ESCAPE.sub(_escape_char, s) + '"'


def _enc_number(x: float) -> str:
    if x.is_integer():
        if abs(x) < 1e17:
            if x == 0 and str(x)[0] == "-":
                return "-0"
            return str(int(x))
        return repr(x)
    if x != x:
        return "null"
    if x in (float("inf"), float("-inf")):
        return "1.7976931348623157e+308" if x > 0 else "-1.7976931348623157e+308"
    return repr(x)


def dumps(v: Any) -> str:
    """Serialize a jq value as compact JSON (the text jq prints with ``-c``)."""
    t = type(v)
    if t is str:
        return _enc_string(v)
    if t is float:
        return _enc_number(v)
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if t is list:
        return "[" + ",".join([dumps(x) for x in v]) + "]"
    if t is Obj:
        return "{" + ",".join([_enc_string(k) + ":" + dumps(x) for k, x in v.items()]) + "}"
    raise TypeError(f"not a jq value: {v!r}")
