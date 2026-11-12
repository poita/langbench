"""The total order on constants, realised as dense integer ranks.

Every integer is below every identifier; integers compare numerically and
identifiers by ASCII byte order.  The engine replaces each constant by its
rank, so comparisons, hashing and sorting all work on plain small ``int``s.
"""

from __future__ import annotations

from typing import Iterable

from .syntax import ConstantValue


def sort_key(value: ConstantValue) -> tuple[int, ConstantValue]:
    """Key realising the constant order for mixed ``int`` / ``str`` values."""
    return (0, value) if isinstance(value, int) else (1, value)


class ConstantTable:
    """Bijection between constants and their ranks in the total order."""

    def __init__(self, constants: Iterable[ConstantValue]) -> None:
        self._values: list[ConstantValue] = sorted(set(constants), key=sort_key)
        self._rank: dict[ConstantValue, int] = {v: i for i, v in enumerate(self._values)}

    def __len__(self) -> int:
        return len(self._values)

    def encode(self, value: ConstantValue) -> int:
        """Rank of ``value``; raises ``KeyError`` for an unknown constant."""
        return self._rank[value]

    def get(self, value: ConstantValue) -> int | None:
        return self._rank.get(value)

    def decode(self, rank: int) -> ConstantValue:
        return self._values[rank]

    @staticmethod
    def render(value: ConstantValue) -> str:
        """Canonical text of a constant."""
        return str(value)
