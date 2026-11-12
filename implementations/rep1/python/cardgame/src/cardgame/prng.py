"""The 64-bit xorshift* generator of SPEC section 25."""

from __future__ import annotations

from typing import MutableSequence

_MASK = (1 << 64) - 1
_MULT = 0x2545F4914F6CDD1D


class Rng:
    """Deterministic xorshift* generator."""

    __slots__ = ("state",)

    def __init__(self, seed: int):
        self.state = (seed & _MASK) or _MULT

    def next(self) -> int:
        """Return the next 64-bit value."""
        s = self.state
        s ^= s >> 12
        s ^= (s << 25) & _MASK
        s ^= s >> 27
        self.state = s
        return (s * _MULT) & _MASK

    def below(self, n: int) -> int:
        """Return a value in ``range(n)`` (``n >= 1``)."""
        return self.next() % n

    def shuffle(self, items: MutableSequence) -> None:
        """Shuffle *items* in place (Fisher-Yates, SPEC section 25)."""
        for i in range(len(items) - 1, 0, -1):
            j = self.below(i + 1)
            items[i], items[j] = items[j], items[i]
