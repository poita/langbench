"""Strict RFC 8259 parser.

The parser is a single forward pass over the decoded text with an explicit
container stack (no recursion, so depth never threatens the interpreter's
stack).  Tokens are recognised with anchored regular expressions on exact
ASCII character classes; no Unicode-aware ``isspace``/``isdigit`` is used.
"""

from __future__ import annotations

import re
from typing import Any

from .errors import JSONError
from .values import Number, Object

#: Maximum nesting depth of arrays/objects.
MAX_DEPTH = 512

_WS = re.compile(r"[ \t\n\r]*").match
_NUMBER = re.compile(
    r"(-?(?:0|[1-9][0-9]*))(\.[0-9]+)?(?:[eE]([+-]?)([0-9]+))?"
).match
_SIMPLE_STRING = re.compile(r'"([^"\\\x00-\x1f]*)"').match
_CHUNK = re.compile(r'[^"\\\x00-\x1f]*').match
_HEX4 = re.compile(r"[0-9A-Fa-f]{4}").match
_LOW_ESC = re.compile(r"\\u([dD][c-fC-F][0-9A-Fa-f]{2})").match

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

# Sentinel appended to the text; it can never be part of a valid token, so
# running off the end always reports an error instead of raising IndexError.
_END = "\x00"


def decode_utf8(data: bytes | bytearray | memoryview) -> str:
    """Validate ``data`` as strict UTF-8 and decode it.

    Overlong forms, encoded surrogates, code points above U+10FFFF and
    truncated sequences are rejected, as is a leading byte-order mark.

    Raises:
        JSONError: if ``data`` is not acceptable.
    """
    data = bytes(data)
    if data.startswith(b"\xef\xbb\xbf"):
        raise JSONError("byte-order mark is not allowed", 0)
    try:
        return data.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise JSONError(f"invalid UTF-8 ({exc.reason})", exc.start) from None


def _parse_string(text: str, pos: int) -> tuple[str, int]:
    """Parse a string whose opening quote is at ``text[pos]``.

    Returns the decoded string and the offset just past the closing quote.
    """
    m = _SIMPLE_STRING(text, pos)
    if m is not None:
        return m.group(1), m.end()
    if text[pos] != '"':
        raise JSONError("expected string", pos)
    pos += 1
    parts: list[str] = []
    while True:
        end = _CHUNK(text, pos).end()
        if end != pos:
            parts.append(text[pos:end])
            pos = end
        c = text[pos]
        if c == '"':
            return "".join(parts), pos + 1
        if c != "\\":
            # control character, or the end-of-text sentinel
            raise JSONError("unterminated string or control character", pos)
        e = text[pos + 1]
        simple = _SIMPLE_ESCAPES.get(e)
        if simple is not None:
            parts.append(simple)
            pos += 2
        elif e == "u":
            h = _HEX4(text, pos + 2)
            if h is None:
                raise JSONError("bad \\u escape", pos)
            code = int(h.group(), 16)
            pos += 6
            if 0xD800 <= code <= 0xDBFF:
                low = _LOW_ESC(text, pos)
                if low is None:
                    raise JSONError("unpaired high surrogate", pos - 6)
                code = 0x10000 + ((code - 0xD800) << 10) + (int(low.group(1), 16) - 0xDC00)
                pos += 6
            elif 0xDC00 <= code <= 0xDFFF:
                raise JSONError("unpaired low surrogate", pos - 6)
            parts.append(chr(code))
        else:
            raise JSONError("invalid escape", pos)


def parse_text(text: str) -> Any:
    """Parse an already decoded document; see :func:`jsoncanon.parse`."""
    text += _END
    last = len(text) - 1
    stack: list[list] = []  # open containers: list (array) or list of pairs (object)
    keys: list[str | None] = []  # pending key per open container; None for arrays
    pos = _WS(text, 0).end()

    while True:
        # ---- a value is expected at pos -------------------------------
        c = text[pos]
        if c == "{" or c == "[":
            if len(stack) >= MAX_DEPTH:
                raise JSONError("maximum nesting depth exceeded", pos)
            pos = _WS(text, pos + 1).end()
            if c == "{":
                if text[pos] == "}":
                    value: Any = Object()
                    pos += 1
                else:
                    key, pos = _parse_key(text, pos)
                    stack.append([])
                    keys.append(key)
                    continue
            else:
                if text[pos] == "]":
                    value = []
                    pos += 1
                else:
                    stack.append([])
                    keys.append(None)
                    continue
        elif c == '"':
            value, pos = _parse_string(text, pos)
        elif c == "t" and text.startswith("true", pos):
            value, pos = True, pos + 4
        elif c == "f" and text.startswith("false", pos):
            value, pos = False, pos + 5
        elif c == "n" and text.startswith("null", pos):
            value, pos = None, pos + 4
        else:
            m = _NUMBER(text, pos)
            if m is None:
                raise JSONError("unexpected character", pos)
            value, pos = _number(m), m.end()

        # ---- a value is complete: attach it and move on ---------------
        while True:
            if not stack:
                pos = _WS(text, pos).end()
                if pos != last:
                    raise JSONError("extra data after document", pos)
                return value
            container = stack[-1]
            key = keys[-1]
            if key is None:
                container.append(value)
            else:
                container.append((key, value))
            pos = _WS(text, pos).end()
            c = text[pos]
            if c == ",":
                pos = _WS(text, pos + 1).end()
                if key is None:
                    break  # next element
                key, pos = _parse_key(text, pos)
                keys[-1] = key
                break
            if c == "]" and key is None:
                value = container
            elif c == "}" and key is not None:
                value = Object(container)
            else:
                raise JSONError("expected ',' or closing bracket", pos)
            stack.pop()
            keys.pop()
            pos += 1


def _parse_key(text: str, pos: int) -> tuple[str, int]:
    """Parse ``string ws ':' ws`` and return the key and the next offset.

    ``pos`` is at the key's opening quote.
    """
    key, pos = _parse_string(text, pos)
    pos = _WS(text, pos).end()
    if text[pos] != ":":
        raise JSONError("expected ':'", pos)
    return key, _WS(text, pos + 1).end()


def _number(m: re.Match[str]) -> Number:
    head, frac, sign, digits = m.groups()
    if digits is None:
        return Number(head if frac is None else head + frac)
    exp = digits.lstrip("0") or "0"
    if sign == "-" and exp != "0":
        exp = "-" + exp
    return Number(f"{head}{frac or ''}e{exp}")
