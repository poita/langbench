"""Parser for the text form accepted by ``encode``.

It accepts the canonical form plus the relaxations of the specification:
optional spaces between tokens, fields in any order, explicit defaults, and
``\\xHH`` string escapes.
"""

from __future__ import annotations

import re
from typing import Any

from .errors import ProtowireError
from .schema import FieldDesc, MessageDesc
from .scalars import BOOL, BYTES, INT, STRING
from .values import Message

_SPACES = re.compile(r" *")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_INT = re.compile(r"-?[0-9]+")
_BYTES = re.compile(r'x"([0-9a-f]*)"')
_CHUNK = re.compile(r'[^"\\\x00-\x1f]*')
_HEX2 = re.compile(r"[0-9a-fA-F]{2}")
_SIMPLE_ESCAPES = {'"': b'"', "\\": b"\\", "n": b"\n", "r": b"\r", "t": b"\t"}
_MAX_INT_DIGITS = 21  # anything longer is out of range for every type


def parse_text(desc: MessageDesc, text: str) -> Message:
    """Parse ``text`` as one text-form message of type ``desc``.

    Raises :class:`ProtowireError` on any syntax, type or range error.
    """
    parser = _Parser(text)
    try:
        return parser.parse_document(desc)
    except UnicodeError:
        raise ProtowireError("string is not valid UTF-8") from None


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.n = len(text)
        self.i = 0

    def fail(self, what: str) -> ProtowireError:
        return ProtowireError(f"{what} at offset {self.i}")

    def skip(self) -> None:
        self.i = _SPACES.match(self.s, self.i).end()

    def parse_document(self, desc: MessageDesc) -> Message:
        self.skip()
        msg = self.parse_message(desc)
        self.skip()
        if self.i != self.n:
            raise self.fail("trailing text")
        return msg

    def parse_message(self, desc: MessageDesc) -> Message:
        s = self.s
        if not s.startswith("{", self.i):
            raise self.fail("expected '{'")
        self.i += 1
        self.skip()
        msg = Message(desc)
        if s.startswith("}", self.i):
            self.i += 1
            return msg
        values = msg.values
        while True:
            m = _IDENT.match(s, self.i)
            if m is None:
                raise self.fail("expected field name")
            fd = desc.by_name.get(m.group())
            if fd is None:
                raise self.fail(f"unknown field {m.group()!r}")
            if fd.number in values:
                raise self.fail(f"duplicate field {fd.name!r}")
            self.i = m.end()
            self.skip()
            if not s.startswith(":", self.i):
                raise self.fail("expected ':'")
            self.i += 1
            self.skip()
            values[fd.number] = self.parse_field_value(fd)
            self.skip()
            if s.startswith(",", self.i):
                self.i += 1
                self.skip()
            elif s.startswith("}", self.i):
                self.i += 1
                return msg
            else:
                raise self.fail("expected ',' or '}'")

    def parse_field_value(self, fd: FieldDesc) -> Any:
        if not fd.repeated:
            return self.parse_element(fd)
        s = self.s
        if not s.startswith("[", self.i):
            raise self.fail("expected '['")
        self.i += 1
        self.skip()
        items: list[Any] = []
        if s.startswith("]", self.i):
            self.i += 1
            return items
        while True:
            items.append(self.parse_element(fd))
            self.skip()
            if s.startswith(",", self.i):
                self.i += 1
                self.skip()
            elif s.startswith("]", self.i):
                self.i += 1
                return items
            else:
                raise self.fail("expected ',' or ']'")

    def parse_element(self, fd: FieldDesc) -> Any:
        scalar = fd.scalar
        if scalar is None:
            return self.parse_message(fd.message)
        category = scalar.category
        if category == INT:
            return self.parse_int(scalar.lo, scalar.hi)
        if category == STRING:
            return self.parse_string()
        if category == BYTES:
            return self.parse_bytes()
        assert category == BOOL
        for word, value in (("true", True), ("false", False)):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return value
        raise self.fail("expected true or false")

    def parse_int(self, lo: int, hi: int) -> int:
        m = _INT.match(self.s, self.i)
        if m is None:
            raise self.fail("expected integer")
        tok = m.group()
        digits = tok.lstrip("-")
        if len(digits) > _MAX_INT_DIGITS or (len(digits) > 1 and digits[0] == "0") or tok == "-0":
            raise self.fail("malformed or out-of-range integer")
        v = int(tok)
        if not lo <= v <= hi:
            raise self.fail("integer out of range")
        self.i = m.end()
        return v

    def parse_bytes(self) -> bytes:
        m = _BYTES.match(self.s, self.i)
        if m is None or len(m.group(1)) % 2:
            raise self.fail("expected bytes literal")
        self.i = m.end()
        return bytes.fromhex(m.group(1))

    def parse_string(self) -> str:
        s = self.s
        start = self.i
        if not s.startswith('"', start):
            raise self.fail("expected string")
        i = start + 1
        j = _CHUNK.match(s, i).end()
        if s.startswith('"', j):  # common case: no escapes
            self.i = j + 1
            return s[i:j]
        buf = bytearray()
        while True:
            buf += s[i:j].encode("utf-8")
            if j >= self.n:
                self.i = j
                raise self.fail("unterminated string")
            c = s[j]
            if c == '"':
                self.i = j + 1
                break
            if c != "\\":
                self.i = j
                raise self.fail("control character in string")
            e = s[j + 1 : j + 2]
            if e in _SIMPLE_ESCAPES:
                buf += _SIMPLE_ESCAPES[e]
                i = j + 2
            elif e == "x" and (h := _HEX2.match(s, j + 2)):
                buf.append(int(h.group(), 16))
                i = j + 4
            else:
                self.i = j
                raise self.fail("bad escape")
            j = _CHUNK.match(s, i).end()
        try:
            return buf.decode("utf-8")
        except UnicodeDecodeError:
            raise self.fail("string is not valid UTF-8") from None
