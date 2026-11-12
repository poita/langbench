"""Record decoding (spec section 1.8)."""

from __future__ import annotations

import struct
from collections.abc import Collection

from .errors import FormatError
from .varint import read_varint

#: A decoded SQL value: NULL, INTEGER, REAL, TEXT or BLOB.
Value = None | int | float | str | bytes

# Byte length of the integer serial types 1..9 (0 for 8 and 9, which are constants).
_INT_SIZES = (0, 1, 2, 3, 4, 6, 8, 8, 0, 0)
_unpack_double = struct.Struct(">d").unpack


def decode_text(raw: bytes) -> str:
    """Decode UTF-8 text. Malformed bytes survive a round trip via surrogateescape."""
    return raw.decode("utf-8", "surrogateescape")


def serial_type_size(serial: int) -> int:
    """Number of body bytes occupied by a value of the given serial type."""
    if serial < 10:
        return _INT_SIZES[serial]
    if serial < 12:
        raise FormatError(f"invalid serial type {serial}")
    return (serial - 12) // 2 if serial % 2 == 0 else (serial - 13) // 2


def decode_record(
    payload: bytes, ncols: int | None = None, wanted: Collection[int] | None = None
) -> list[Value]:
    """Decode a record into a list of values.

    ``ncols`` pads the result with NULLs up to that many columns (records may
    be short after ``ALTER TABLE ADD COLUMN``). When ``wanted`` is given, only
    those column indexes are decoded and every other slot is left ``None``;
    this skips the cost of decoding unused columns.
    """
    header_size, pos = read_varint(payload, 0)
    if header_size > len(payload):
        raise FormatError("record header overruns payload")
    serials: list[int] = []
    while pos < header_size:
        serial, pos = read_varint(payload, pos)
        serials.append(serial)
    out: list[Value] = [None] * max(len(serials), ncols or 0)
    last = len(serials) - 1 if wanted is None else min(max(wanted, default=-1), len(serials) - 1)
    body = header_size
    for i in range(last + 1):
        serial = serials[i]
        if serial == 0:
            continue
        size = serial_type_size(serial)
        if wanted is None or i in wanted:
            if body + size > len(payload):
                raise FormatError("record body overruns payload")
            if serial < 10:
                if serial == 8:
                    out[i] = 0
                elif serial == 9:
                    out[i] = 1
                elif serial == 7:
                    out[i] = _unpack_double(payload[body : body + 8])[0]
                else:
                    out[i] = int.from_bytes(payload[body : body + size], "big", signed=True)
            elif serial & 1:
                out[i] = decode_text(payload[body : body + size])
            else:
                out[i] = payload[body : body + size]
        body += size
    return out
