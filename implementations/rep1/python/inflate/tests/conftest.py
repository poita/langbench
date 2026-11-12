"""Shared helpers: a tiny bit writer for hand-crafting DEFLATE streams."""

from __future__ import annotations


class BitWriter:
    def __init__(self) -> None:
        self.value = 0
        self.nbits = 0

    def bits(self, value: int, n: int) -> "BitWriter":
        """Append an ``n``-bit number, LSB first."""
        self.value |= value << self.nbits
        self.nbits += n
        return self

    def code(self, code: int, n: int) -> "BitWriter":
        """Append an ``n``-bit Huffman code, MSB first."""
        for i in range(n - 1, -1, -1):
            self.bits((code >> i) & 1, 1)
        return self

    def to_bytes(self) -> bytes:
        return self.value.to_bytes((self.nbits + 7) // 8, "little")


def fixed_lit(w: BitWriter, sym: int) -> BitWriter:
    """Write literal/length symbol ``sym`` with the fixed code."""
    if sym < 144:
        return w.code(0x30 + sym, 8)
    if sym < 256:
        return w.code(0x190 + sym - 144, 9)
    if sym < 280:
        return w.code(sym - 256, 7)
    return w.code(0xC0 + sym - 280, 8)
