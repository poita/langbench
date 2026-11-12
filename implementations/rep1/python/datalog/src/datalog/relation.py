"""Relations: sets of tuples with incrementally maintained hash indexes."""

from __future__ import annotations

from collections import defaultdict
from operator import itemgetter
from typing import Callable, Iterable

Row = tuple[int, ...]
Index = defaultdict  # key -> list[Row]


class Relation:
    """A set of equal-length tuples.

    An index is identified by the tuple of argument positions it is keyed on.
    It is built once, on first request, by scanning the relation, and from then
    on updated by :meth:`add_all` -- never rebuilt.  The key of a one-position
    index is the bare value; otherwise it is the tuple of values.
    """

    __slots__ = ("name", "arity", "tuples", "_indexes")

    def __init__(self, name: str, arity: int) -> None:
        self.name = name
        self.arity = arity
        self.tuples: set[Row] = set()
        self._indexes: dict[tuple[int, ...], tuple[Callable[[Row], object], Index]] = {}

    def __len__(self) -> int:
        return len(self.tuples)

    def __contains__(self, row: Row) -> bool:
        return row in self.tuples

    @staticmethod
    def _getter(positions: tuple[int, ...]) -> Callable[[Row], object]:
        return itemgetter(*positions)

    def add_all(self, rows: Iterable[Row]) -> list[Row]:
        """Insert rows; return the ones that were not present yet (the delta),
        in insertion order.  Every maintained index is updated."""
        present = self.tuples
        added: list[Row] = []
        for row in rows:
            if row not in present:
                present.add(row)
                added.append(row)
        for getter, index in self._indexes.values():
            for row in added:
                index[getter(row)].append(row)
        return added

    def index(self, positions: tuple[int, ...]) -> Index:
        """The (live) index on ``positions``, created on first use."""
        entry = self._indexes.get(positions)
        if entry is None:
            getter = self._getter(positions)
            idx: Index = defaultdict(list)
            for row in self.tuples:
                idx[getter(row)].append(row)
            entry = self._indexes[positions] = (getter, idx)
        return entry[1]

    def lookup(self, positions: tuple[int, ...], key: object) -> Iterable[Row]:
        """Rows whose values at ``positions`` equal ``key`` (all rows when
        ``positions`` is empty)."""
        if not positions:
            return self.tuples
        return self.index(positions).get(key, ())
