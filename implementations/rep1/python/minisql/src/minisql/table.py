"""Table storage."""

from __future__ import annotations

from .values import Value


class Table:
    """A named table: ordered column names and rows in insertion order."""

    __slots__ = ("name", "columns", "rows", "_index")

    def __init__(self, name: str, columns: list[str]) -> None:
        self.name = name
        self.columns = list(columns)
        self.rows: list[tuple[Value, ...]] = []
        self._index = {c: i for i, c in enumerate(self.columns)}

    def column_index(self, name: str) -> int | None:
        """Position of the (lower-case) column ``name``, or None."""
        return self._index.get(name)
