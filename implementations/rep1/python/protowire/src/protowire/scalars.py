"""Scalar field types: wire type, value conversion and range of each."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .errors import ProtowireError

M32 = 0xFFFFFFFF
M64 = 0xFFFFFFFFFFFFFFFF

# Wire types.
VARINT = 0
FIXED64 = 1
LEN = 2
START_GROUP = 3
END_GROUP = 4
FIXED32 = 5

# Value categories, used by the text codecs.
INT = "int"
BOOL = "bool"
STRING = "string"
BYTES = "bytes"


@dataclass(frozen=True, slots=True)
class Scalar:
    """Description of one scalar type.

    ``from_wire`` turns the raw wire payload into the natural Python value:
    for varint and fixed types the unsigned integer read from the wire, for
    length-delimited types the payload ``bytes``. ``to_wire`` is the inverse
    for numeric types (the natural value to an unsigned wire integer).
    """

    name: str
    wire_type: int
    category: str
    from_wire: Callable[[Any], Any]
    to_wire: Callable[[Any], Any]
    lo: int = 0
    hi: int = 0

    @property
    def packable(self) -> bool:
        """True for numeric types, which repeated fields may pack."""
        return self.wire_type != LEN

    @property
    def fixed_size(self) -> int:
        """Bytes per element for fixed32/fixed64 types, else 0."""
        return {FIXED32: 4, FIXED64: 8}.get(self.wire_type, 0)


def _signed(bits: int) -> Callable[[int], int]:
    sign, full = 1 << (bits - 1), 1 << bits
    mask = full - 1

    def conv(v: int) -> int:
        v &= mask
        return v - full if v & sign else v

    return conv


def _unsigned(bits: int) -> Callable[[int], int]:
    mask = (1 << bits) - 1
    return lambda v: v & mask


def _zigzag_decode(bits: int) -> Callable[[int], int]:
    mask = (1 << bits) - 1

    def conv(v: int) -> int:
        u = v & mask
        return (u >> 1) ^ -(u & 1)

    return conv


def _zigzag_encode(bits: int) -> Callable[[int], int]:
    mask = (1 << bits) - 1
    return lambda v: ((v << 1) ^ (v >> (bits - 1))) & mask


def _decode_utf8(payload: bytes) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        raise ProtowireError("invalid UTF-8 in string") from None


def _encode_utf8(value: str) -> bytes:
    try:
        return value.encode("utf-8")
    except UnicodeEncodeError:
        raise ProtowireError("string is not encodable as UTF-8") from None


def _identity(v: Any) -> Any:
    return v


def _num(name: str, wire_type: int, bits: int, signed: bool, from_wire, to_wire) -> Scalar:
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    return Scalar(name, wire_type, INT, from_wire, to_wire, lo, hi)


SCALARS: dict[str, Scalar] = {
    s.name: s
    for s in (
        _num("int32", VARINT, 32, True, _signed(32), _unsigned(64)),
        _num("int64", VARINT, 64, True, _signed(64), _unsigned(64)),
        _num("uint32", VARINT, 32, False, _unsigned(32), _identity),
        _num("uint64", VARINT, 64, False, _unsigned(64), _identity),
        _num("sint32", VARINT, 32, True, _zigzag_decode(32), _zigzag_encode(32)),
        _num("sint64", VARINT, 64, True, _zigzag_decode(64), _zigzag_encode(64)),
        Scalar("bool", VARINT, BOOL, lambda v: v != 0, int),
        _num("fixed32", FIXED32, 32, False, _identity, _identity),
        _num("sfixed32", FIXED32, 32, True, _signed(32), _unsigned(32)),
        _num("fixed64", FIXED64, 64, False, _identity, _identity),
        _num("sfixed64", FIXED64, 64, True, _signed(64), _unsigned(64)),
        Scalar("string", LEN, STRING, _decode_utf8, _encode_utf8),
        Scalar("bytes", LEN, BYTES, bytes, _identity),
    )
}
