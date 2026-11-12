"""FNV-1a 64-bit content hashing."""

from __future__ import annotations

_OFFSET = 0xCBF29CE484222325
_PRIME = 0x100000001B3
_MASK = 0xFFFFFFFFFFFFFFFF


def fnv1a64(data: bytes) -> int:
    """The 64-bit FNV-1a hash of *data* as an integer."""
    h = _OFFSET
    for b in data:
        h = ((h ^ b) * _PRIME) & _MASK
    return h


def hash_hex(data: bytes) -> bytes:
    """The hash of *data* as 16 lowercase hex digits."""
    return b"%016x" % fnv1a64(data)
