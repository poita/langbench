"""SQLite variable-length integers (spec section 1.3)."""

from __future__ import annotations

from .errors import FormatError


def read_varint(data: bytes | memoryview, pos: int) -> tuple[int, int]:
    """Decode the varint at ``data[pos:]``.

    Returns ``(value, next_pos)``. The value is a signed 64-bit integer: a
    nine-byte varint carries a full 8 bits in its last byte, so values with the
    top bit set are negative.
    """
    try:
        b = data[pos]
        if b < 0x80:  # by far the most common case
            return b, pos + 1
        value = b & 0x7F
        for i in range(1, 8):
            b = data[pos + i]
            value = (value << 7) | (b & 0x7F)
            if b < 0x80:
                return value, pos + i + 1
        value = (value << 8) | data[pos + 8]
    except IndexError:
        raise FormatError("truncated varint") from None
    if value >= 1 << 63:
        value -= 1 << 64
    return value, pos + 9
