"""protowire: a Protocol Buffers wire-format codec with a canonical text form.

Typical use::

    from protowire import parse_schema, decode, encode

    schema = parse_schema("message M { int32 a = 1; repeated string s = 2; }")
    data = encode(schema, "M", '{a: 1, s: ["x"]}')   # bytes
    text = decode(schema, "M", data)                 # '{a: 1, s: ["x"]}'

Lower-level pieces (:func:`decode_message`, :func:`encode_message`,
:func:`parse_text`, :func:`format_message`) work on :class:`Message` trees.
"""

from __future__ import annotations

from .decoder import decode_message
from .encoder import encode_message
from .errors import ProtowireError, SchemaError
from .schema import FieldDesc, MessageDesc, Schema, parse_schema
from .textfmt import format_message
from .textparse import parse_text
from .values import Message

__version__ = "1.0.0"

__all__ = [
    "FieldDesc",
    "Message",
    "MessageDesc",
    "ProtowireError",
    "Schema",
    "SchemaError",
    "decode",
    "decode_message",
    "encode",
    "encode_message",
    "format_message",
    "parse_schema",
    "parse_text",
]


def decode(schema: Schema, message: str, data: bytes) -> str:
    """Decode wire ``data`` as message type ``message`` and return its canonical text."""
    return format_message(decode_message(schema[message], data))


def encode(schema: Schema, message: str, text: str) -> bytes:
    """Encode text-form ``text`` as message type ``message`` and return the wire bytes."""
    return encode_message(parse_text(schema[message], text))
