"""Relations: sets of tuples with incrementally maintained hash indexes."""

from __future__ import annotations

from operator import itemgetter
from typing import Callable, Iterable, Iterator

Row = tuple[int, ...]


class Relation:
    """A set of equal-length integer tuples.

    ``index(positions)`` returns a dict mapping the values at ``positions`` (a
    bare value for one position, a tuple for several) to the list of tuples
    having them.  An index is built once, on first request, and from then on
    kept current by :meth:`add_all`, so its total cost is linear in the size of
    the relation.
    """

    __slots__ = ("name", "arity", "tuples", "_indexes")

    def __init__(self, name: str, arity: int) -> None:
        self.name = name
        self.arity = arity
        self.tuples: set[Row] = set()
        self._indexes: dict[tuple[int, ...], tuple[Callable[[Row], object], dict]] = {}

    def __len__(self) -> int:
        return len(self.tuples)

    def __iter__(self) -> Iterator[Row]:
        return iter(self.tuples)

    def __contains__(self, row: Row) -> bool:
        return row in self.tuples

    def add_all(self, rows: Iterable[Row]) -> list[Row]:
        """Insert ``rows``; return those that were not already present."""
        present = self.tuples
        if not isinstance(rows, (set, frozenset)):
            rows = dict.fromkeys(rows)  # drop duplicates, keep order
        fresh = [r for r in rows if r not in present]
        present.update(fresh)
        for getter, table in self._indexes.values():
            get = table.get
            for row in fresh:
                key = getter(row)
                bucket = get(key)
                if bucket is None:
                    table[key] = [row]
                else:
                    bucket.append(row)
        return fresh

    def index(self, positions: tuple[int, ...]) -> dict:
        """The hash index on ``positions`` (a non-empty tuple of argument
        positions), created and filled on first use."""
        entry = self._indexes.get(positions)
        if entry is None:
            getter = itemgetter(*positions)
            table: dict = {}
            for row in self.tuples:
                key = getter(row)
                bucket = table.get(key)
                if bucket is None:
                    table[key] = [row]
                else:
                    bucket.append(row)
            self._indexes[positions] = (getter, table)
            return table
        return entry[1]


class Database:
    """The relations of a program, keyed by ``(name, arity)``, created on
    demand (an unknown predicate is an empty relation)."""

    def __init__(self) -> None:
        self._relations: dict[tuple[str, int], Relation] = {}

    def relation(self, name: str, arity: int) -> Relation:
        key = (name, arity)
        rel = self._relations.get(key)
        if rel is None:
            rel = self._relations[key] = Relation(name, arity)
        return rel

    def get(self, name: str, arity: int) -> Relation | None:
        return self._relations.get((name, arity))
