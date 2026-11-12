"""Adler-32, implemented by hand."""

from __future__ import annotations

from operator import mul

_MOD = 65521
#: Largest block for which the textbook algorithm can defer the modulo; we use
#: it only to keep the intermediate integers small.
_BLOCK = 5552


def adler32(data: bytes) -> int:
    """Return the Adler-32 checksum of *data* as an integer."""
    a, b = 1, 0
    for start in range(0, len(data), _BLOCK):
        chunk = data[start:start + _BLOCK]
        n = len(chunk)
        # b gains the running value of ``a`` after every byte of the block.
        b += n * a + sum(map(mul, chunk, range(n, 0, -1)))
        a += sum(chunk)
        a %= _MOD
        b %= _MOD
    return (b << 16) | a


def adler32_hex(data: bytes) -> str:
    """Return :func:`adler32` as exactly eight lower-case hex digits."""
    return f"{adler32(data):08x}"
