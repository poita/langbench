"""A small recursive-descent JSON parser (RFC 8259) producing exact numbers.

The parser keeps every number as an exact rational taken from the literal (see
:mod:`jsonschema2020.jsonvalue`) and keeps object members in document order.
"""

from __future__ import annotations

from fractions import Fraction
from typing import Any

__all__ = ["JSONParseError", "loads"]

_WS = " \t\n\r"
_DIGITS = "0123456789"
_ESCAPES = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
}
_HEX = frozenset("0123456789abcdefABCDEF")
#: Decimal exponents beyond this are rejected rather than expanded.
_MAX_EXPONENT = 100_000


class JSONParseError(ValueError):
    """Raised for malformed JSON; ``pos`` is the offending character offset."""

    def __init__(self, message: str, pos: int) -> None:
        super().__init__(f"{message} at offset {pos}")
        self.pos = pos


def loads(text: str) -> Any:
    """Parse *text* (a ``str``) holding exactly one JSON value.

    Raises :class:`JSONParseError` on malformed input.
    """
    if text.startswith("\ufeff"):
        text = text[1:]
    parser = _Parser(text)
    value = parser.parse_document()
    return value


class _Parser:
    __slots__ = ("text", "pos", "n")

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0
        self.n = len(text)

    def error(self, message: str) -> JSONParseError:
        return JSONParseError(message, self.pos)

    def skip_ws(self) -> None:
        text, pos, n = self.text, self.pos, self.n
        while pos < n and text[pos] in _WS:
            pos += 1
        self.pos = pos

    def parse_document(self) -> Any:
        self.skip_ws()
        value = self.parse_value()
        self.skip_ws()
        if self.pos != self.n:
            raise self.error("unexpected trailing data")
        return value

    def parse_value(self) -> Any:
        if self.pos >= self.n:
            raise self.error("unexpected end of input")
        ch = self.text[self.pos]
        if ch == '"':
            return self.parse_string()
        if ch == "{":
            return self.parse_object()
        if ch == "[":
            return self.parse_array()
        if ch == "-" or ch in _DIGITS:
            return self.parse_number()
        if self.text.startswith("true", self.pos):
            self.pos += 4
            return True
        if self.text.startswith("false", self.pos):
            self.pos += 5
            return False
        if self.text.startswith("null", self.pos):
            self.pos += 4
            return None
        raise self.error("unexpected character")

    def parse_object(self) -> dict:
        text = self.text
        self.pos += 1
        result: dict = {}
        self.skip_ws()
        if self.pos < self.n and text[self.pos] == "}":
            self.pos += 1
            return result
        while True:
            self.skip_ws()
            if self.pos >= self.n or text[self.pos] != '"':
                raise self.error("expected string key")
            key = self.parse_string()
            self.skip_ws()
            if self.pos >= self.n or text[self.pos] != ":":
                raise self.error("expected ':'")
            self.pos += 1
            self.skip_ws()
            result[key] = self.parse_value()
            self.skip_ws()
            if self.pos >= self.n:
                raise self.error("unterminated object")
            ch = text[self.pos]
            self.pos += 1
            if ch == ",":
                continue
            if ch == "}":
                return result
            self.pos -= 1
            raise self.error("expected ',' or '}'")

    def parse_array(self) -> list:
        text = self.text
        self.pos += 1
        result: list = []
        self.skip_ws()
        if self.pos < self.n and text[self.pos] == "]":
            self.pos += 1
            return result
        while True:
            self.skip_ws()
            result.append(self.parse_value())
            self.skip_ws()
            if self.pos >= self.n:
                raise self.error("unterminated array")
            ch = text[self.pos]
            self.pos += 1
            if ch == ",":
                continue
            if ch == "]":
                return result
            self.pos -= 1
            raise self.error("expected ',' or ']'")

    def parse_string(self) -> str:
        text = self.text
        i = self.pos + 1
        end = text.find('"', i)
        if end < 0:
            raise self.error("unterminated string")
        backslash = text.find("\\", i, end)
        if backslash < 0:
            self.pos = end + 1
            return text[i:end]
        parts = []
        while True:
            end = text.find('"', i)
            if end < 0:
                raise JSONParseError("unterminated string", self.pos)
            backslash = text.find("\\", i, end)
            if backslash < 0:
                parts.append(text[i:end])
                self.pos = end + 1
                return "".join(parts)
            parts.append(text[i:backslash])
            i = backslash + 1
            if i >= self.n:
                raise JSONParseError("unterminated string", backslash)
            esc = text[i]
            if esc == "u":
                code = self._hex4(i + 1)
                i += 5
                if 0xD800 <= code < 0xDC00 and text.startswith("\\u", i):
                    low = self._hex4(i + 2)
                    if 0xDC00 <= low < 0xE000:
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        i += 6
                parts.append(chr(code))
            else:
                try:
                    parts.append(_ESCAPES[esc])
                except KeyError:
                    raise JSONParseError("invalid escape", i) from None
                i += 1

    def _hex4(self, start: int) -> int:
        digits = self.text[start : start + 4]
        if len(digits) != 4 or any(c not in _HEX for c in digits):
            raise JSONParseError("invalid \\u escape", start)
        return int(digits, 16)

    def parse_number(self) -> Any:
        text, n = self.text, self.n
        start = i = self.pos
        if text[i] == "-":
            i += 1
        if i >= n or text[i] not in _DIGITS:
            self.pos = i
            raise self.error("invalid number")
        if text[i] == "0":
            i += 1
        else:
            while i < n and text[i] in _DIGITS:
                i += 1
        int_end = i
        frac_digits = 0
        frac_start = frac_end = i
        if i < n and text[i] == ".":
            i += 1
            frac_start = i
            while i < n and text[i] in _DIGITS:
                i += 1
            frac_end = i
            frac_digits = frac_end - frac_start
            if frac_digits == 0:
                self.pos = i
                raise self.error("invalid number")
        exponent = 0
        if i < n and text[i] in "eE":
            i += 1
            sign = 1
            if i < n and text[i] in "+-":
                if text[i] == "-":
                    sign = -1
                i += 1
            exp_start = i
            while i < n and text[i] in _DIGITS:
                i += 1
            if i == exp_start:
                self.pos = i
                raise self.error("invalid number")
            exponent = sign * int(text[exp_start:i])
        self.pos = i
        negative = text[start] == "-"
        int_digits = text[start + 1 if negative else start : int_end]
        if frac_digits:
            mantissa = int(int_digits + text[frac_start:frac_end])
        else:
            mantissa = int(int_digits)
        exponent -= frac_digits
        if mantissa == 0:
            return 0
        if abs(exponent) > _MAX_EXPONENT:
            raise self.error("exponent out of range")
        if negative:
            mantissa = -mantissa
        if exponent >= 0:
            return mantissa * 10**exponent if exponent else mantissa
        value = Fraction(mantissa, 10**-exponent)
        return value.numerator if value.denominator == 1 else value
