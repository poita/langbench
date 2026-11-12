"""Semantic versions (``MAJOR.MINOR.PATCH``, no prerelease or build parts)."""

from __future__ import annotations

from typing import NamedTuple

#: Bits reserved for each component of an encoded version key. Components are
#: at most 1,000,000 and range bounds may add one, so 21 bits (2,097,152) suffice.
COMPONENT_BITS = 21

#: Exclusive upper bound of every encoded version key.
KEY_LIMIT = 1 << (3 * COMPONENT_BITS)


class Version(NamedTuple):
    """An immutable ``major.minor.patch`` version.

    Versions are tuples, so they compare numerically component by component
    (``Version(1, 10, 0) > Version(1, 9, 0)``) and are hashable.
    """

    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, text: str) -> Version:
        """Parse ``"1.2.3"``. Raises :class:`ValueError` on malformed text."""
        parts = text.split(".")
        if len(parts) != 3 or not all(p.isascii() and p.isdigit() for p in parts):
            raise ValueError(f"invalid version: {text!r}")
        return cls(int(parts[0]), int(parts[1]), int(parts[2]))

    @property
    def key(self) -> int:
        """An integer whose order matches the version order.

        ``key(a) < key(b)`` iff ``a < b``, and ``key + 1`` is the smallest key
        greater than this one, which makes half-open intervals easy to express.
        """
        return (
            (self.major << (2 * COMPONENT_BITS))
            | (self.minor << COMPONENT_BITS)
            | self.patch
        )

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"
