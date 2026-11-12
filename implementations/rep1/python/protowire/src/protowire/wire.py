"""Low-level wire-format primitives: varints, tags, lengths and field skipping.

All readers take ``(data, pos, end)`` and never look at or beyond ``end``;
they return the value and the new position, and raise
:class:`~protowire.errors.ProtowireError` on malformed input.
"""

from __future__ import annotations

from .errors import ProtowireError
from .scalars import END_GROUP, FIXED32, FIXED64, LEN, M64, START_GROUP, VARINT

MAX_VARINT_BYTES = 10
MAX_TAG_BYTES = 5
MAX_LENGTH_BYTES = 5


def read_varint(data: bytes, pos: int, end: int, max_bytes: int = MAX_VARINT_BYTES) -> tuple[int, int]:
    """Read a varint of at most ``max_bytes`` bytes, modulo 2**64."""
    if pos >= end:
        raise ProtowireError("truncated varint")
    b = data[pos]
    if b < 0x80:
        return b, pos + 1
    result = b & 0x7F
    shift = 7
    i = pos + 1
    limit = pos + max_bytes
    while True:
        if i >= end:
            raise ProtowireError("truncated varint")
        if i >= limit:
            raise ProtowireError("varint too long")
        b = data[i]
        i += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result & M64, i
        shift += 7


def read_tag(data: bytes, pos: int, end: int) -> tuple[int, int, int]:
    """Read a tag; return ``(field_number, wire_type, new_pos)``.

    Enforces the tag rules: at most 5 bytes, value below 2**32, field number
    at least 1 and wire type in 0..5 (end-group is returned to the caller).
    """
    tag, pos = read_varint(data, pos, end, MAX_TAG_BYTES)
    if tag >> 32:
        raise ProtowireError("tag out of range")
    number = tag >> 3
    wire_type = tag & 7
    if number == 0:
        raise ProtowireError("field number 0")
    if wire_type > FIXED32 or wire_type == 6:
        raise ProtowireError(f"invalid wire type {wire_type}")
    return number, wire_type, pos


def read_length(data: bytes, pos: int, end: int) -> tuple[int, int]:
    """Read a length prefix; the length must fit in the bytes up to ``end``."""
    n, pos = read_varint(data, pos, end, MAX_LENGTH_BYTES)
    if n > end - pos:
        raise ProtowireError("length exceeds remaining bytes")
    return n, pos


def skip_payload(data: bytes, pos: int, end: int, wire_type: int) -> int:
    """Skip the payload of a non-group field and return the new position."""
    if wire_type == VARINT:
        return read_varint(data, pos, end)[1]
    if wire_type == LEN:
        n, pos = read_length(data, pos, end)
        return pos + n
    if wire_type == FIXED32:
        size = 4
    elif wire_type == FIXED64:
        size = 8
    else:
        raise ProtowireError(f"cannot skip wire type {wire_type}")
    if end - pos < size:
        raise ProtowireError("truncated fixed-size value")
    return pos + size


def skip_group(data: bytes, pos: int, end: int, number: int) -> int:
    """Skip a group body whose start tag (field ``number``) was just read.

    Returns the position after the matching end-group tag. Nested groups are
    tracked with an explicit stack, so each byte is read once.
    """
    stack = [number]
    while stack:
        num, wt, pos = read_tag(data, pos, end)
        if wt == END_GROUP:
            if num != stack.pop():
                raise ProtowireError("mismatched end-group tag")
        elif wt == START_GROUP:
            stack.append(num)
        else:
            pos = skip_payload(data, pos, end, wt)
    return pos


def skip_field(data: bytes, pos: int, end: int, number: int, wire_type: int) -> int:
    """Skip one field whose tag was just read, whatever its wire type."""
    if wire_type == START_GROUP:
        return skip_group(data, pos, end, number)
    if wire_type == END_GROUP:
        raise ProtowireError("unexpected end-group tag")
    return skip_payload(data, pos, end, wire_type)


def put_varint(out: bytearray, v: int) -> None:
    """Append ``v`` (0 <= v < 2**64) to ``out`` as a minimal varint."""
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)


def varint_size(v: int) -> int:
    """Number of bytes in the minimal varint encoding of ``v``."""
    return (v.bit_length() + 6) // 7 or 1
