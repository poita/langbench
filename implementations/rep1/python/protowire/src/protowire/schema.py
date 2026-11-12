"""Schema model and parser for the ``message Name { type name = N; }`` language."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .errors import SchemaError
from .scalars import LEN, SCALARS, Scalar

_TOKEN = re.compile(r"[{};=]|[A-Za-z0-9_]+")
_WHITESPACE = frozenset(" \t\r\n")


@dataclass(eq=False, slots=True)
class FieldDesc:
    """One field of a message. Exactly one of ``scalar`` / ``message`` is set."""

    name: str
    number: int
    repeated: bool
    scalar: Scalar | None = None
    message: MessageDesc | None = None
    #: Precomputed tag bytes: ``tag`` for the field's own wire type (for
    #: messages and strings/bytes that is length-delimited) and ``packed_tag``
    #: for the packed form of repeated numeric fields.
    tag: bytes = b""
    packed_tag: bytes = b""

    @property
    def packed(self) -> bool:
        """True if the field is a repeated numeric field (encoded packed)."""
        return self.repeated and self.scalar is not None and self.scalar.packable


@dataclass(eq=False, slots=True)
class MessageDesc:
    """A message type: its fields indexed by number and by name."""

    name: str
    fields: list[FieldDesc] = field(default_factory=list)
    by_number: dict[int, FieldDesc] = field(default_factory=dict)
    by_name: dict[str, FieldDesc] = field(default_factory=dict)


class Schema:
    """A parsed schema: message descriptors by name."""

    def __init__(self, messages: dict[str, MessageDesc]):
        self.messages = messages

    def __getitem__(self, name: str) -> MessageDesc:
        return self.messages[name]

    def __contains__(self, name: object) -> bool:
        return name in self.messages

    def get(self, name: str) -> MessageDesc | None:
        return self.messages.get(name)


def _varint_bytes(v: int) -> bytes:
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def _tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    pos, n = 0, len(text)
    while pos < n:
        if text[pos] in _WHITESPACE:
            pos += 1
            continue
        m = _TOKEN.match(text, pos)
        if m is None:
            raise SchemaError(f"unexpected character {text[pos]!r} in schema")
        tokens.append(m.group())
        pos = m.end()
    return tokens


def parse_schema(text: str) -> Schema:
    """Parse schema source text into a :class:`Schema`.

    Raises :class:`SchemaError` if the text is not a valid schema.
    """
    tokens = _tokenize(text)
    pos = 0

    def next_token() -> str:
        nonlocal pos
        if pos >= len(tokens):
            raise SchemaError("unexpected end of schema")
        pos += 1
        return tokens[pos - 1]

    def expect(tok: str) -> None:
        got = next_token()
        if got != tok:
            raise SchemaError(f"expected {tok!r}, got {got!r}")

    # (message, [(repeated, type name, field name, number)])
    raw: list[tuple[MessageDesc, list[tuple[bool, str, str, int]]]] = []
    messages: dict[str, MessageDesc] = {}
    while pos < len(tokens):
        expect("message")
        name = next_token()
        if name in messages:
            raise SchemaError(f"duplicate message {name!r}")
        desc = MessageDesc(name)
        messages[name] = desc
        expect("{")
        fields: list[tuple[bool, str, str, int]] = []
        while True:
            tok = next_token()
            if tok == "}":
                break
            repeated = tok == "repeated"
            type_name = next_token() if repeated else tok
            field_name = next_token()
            expect("=")
            number_tok = next_token()
            if not number_tok.isascii() or not number_tok.isdigit():
                raise SchemaError(f"bad field number {number_tok!r}")
            expect(";")
            fields.append((repeated, type_name, field_name, int(number_tok)))
        raw.append((desc, fields))

    for desc, fields in raw:
        for repeated, type_name, field_name, number in fields:
            if number in desc.by_number or field_name in desc.by_name:
                raise SchemaError(f"duplicate field in {desc.name}: {field_name}")
            scalar = SCALARS.get(type_name)
            message = None
            if scalar is None:
                message = messages.get(type_name)
                if message is None:
                    raise SchemaError(f"unknown type {type_name!r}")
            fd = FieldDesc(field_name, number, repeated, scalar, message)
            wt = scalar.wire_type if scalar is not None else LEN
            fd.tag = _varint_bytes((number << 3) | wt)
            fd.packed_tag = _varint_bytes((number << 3) | LEN)
            desc.fields.append(fd)
            desc.by_number[number] = fd
            desc.by_name[field_name] = fd
    return Schema(messages)
