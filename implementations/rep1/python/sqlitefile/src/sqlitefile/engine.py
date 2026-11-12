"""Query execution against an open database (spec Part 4 and the approach notes)."""

from __future__ import annotations

import operator
from collections.abc import Callable, Iterator
from pathlib import Path

from . import btree
from .errors import QueryError
from .pager import Pager
from .query import (
    Condition,
    CountQuery,
    IndexQuery,
    Query,
    SchemaQuery,
    SelectQuery,
    TablesQuery,
    parse_query,
)
from .record import Value, decode_record
from .schema import Catalog, Table
from .values import REAL, apply_affinity, ascii_lower, format_value, sort_key


class Database:
    """A SQLite database file opened for reading.

    The whole file is held in memory. The catalog (``sqlite_schema``) is read
    once on construction; every query walks the B-trees afresh and nothing else
    is cached between queries.
    """

    def __init__(self, data: bytes) -> None:
        self.pager = Pager(data)
        self.catalog = Catalog.read(self.pager)

    @classmethod
    def open(cls, path: str | Path) -> "Database":
        """Open the database file at ``path``."""
        return cls(Path(path).read_bytes())

    # -- public conveniences ---------------------------------------------

    def run(self, line: str) -> list[str]:
        """Execute one query line and return its output rows (without final newlines).

        Each entry is one result row; a ``.schema`` entry may itself contain
        newlines because stored ``CREATE`` statements can span several lines.

        Raises :class:`~sqlitefile.errors.QueryError` for malformed queries and
        unknown names.
        """
        return list(self.execute(parse_query(line)))

    def execute(self, query: Query) -> Iterator[str]:
        """Execute a parsed query, yielding output lines lazily."""
        if isinstance(query, TablesQuery):
            return iter(self.table_names())
        if isinstance(query, SchemaQuery):
            return iter(self.schema_sql(query.table))
        if isinstance(query, CountQuery):
            return iter([str(self.count(query.table))])
        if isinstance(query, SelectQuery):
            return self._select_lines(query)
        if isinstance(query, IndexQuery):
            return self._index_lines(query)
        raise TypeError(f"not a query: {query!r}")  # pragma: no cover

    def table_names(self) -> list[str]:
        """User tables, sorted by UTF-8 byte order (the ``.tables`` command)."""
        names = [
            r.name
            for r in self.catalog.rows
            if r.type == "table" and r.name is not None
            and not ascii_lower(r.name).startswith("sqlite_")
        ]  # fmt: skip
        return sorted(names, key=lambda n: n.encode("utf-8", "surrogateescape"))

    def schema_sql(self, table: str) -> list[str]:
        """The ``CREATE`` statements attached to ``table``, each ending in ``;``."""
        folded = ascii_lower(table)
        return [
            r.sql + ";"
            for r in self.catalog.rows
            if r.sql is not None and r.tbl_name is not None and ascii_lower(r.tbl_name) == folded
        ]

    def count(self, table: str) -> int:
        """Number of rows in ``table``, without reading any record."""
        return btree.count_table(self.pager, self._table(table).root_page)

    # -- SELECT -------------------------------------------------------------

    def _table(self, name: str) -> Table:
        table = self.catalog.table(name)
        if table is None:
            raise QueryError(f"no such table: {name}")
        return table

    def _usable_table(self, name: str) -> Table:
        table = self._table(name)
        if table.columns is None:
            raise QueryError(f"cannot read table {name}")
        return table

    def select_rows(self, query: SelectQuery) -> Iterator[list[Value]]:
        """Run a ``SELECT`` and yield each result row as a list of values."""
        table = self._usable_table(query.table)
        columns = table.columns or ()
        if query.columns is None:
            out_refs = [(i, c.affinity) for i, c in enumerate(columns)]
        else:
            out_refs = [self._column(table, c) for c in query.columns]
        tests = [self._condition(table, c) for c in query.where]
        order_ref = self._column(table, query.order_by.column) if query.order_by else None

        refs = out_refs + [t[0] for t in tests] + ([order_ref] if order_ref else [])
        wanted = {i for i, _ in refs if i >= 0}
        real_cols = [i for i in wanted if columns[i].affinity == REAL]
        alias = table.rowid_alias
        ncols = len(columns)

        def rows() -> Iterator[tuple[int, list[Value]]]:
            for rowid, payload in btree.iter_table(self.pager, table.root_page):
                vals = decode_record(payload, ncols, wanted)
                if alias is not None:
                    vals[alias] = rowid
                for i in real_cols:
                    if type(vals[i]) is int:
                        vals[i] = float(vals[i])
                # Index -1 (rowid) is reached as vals[-1]; keep rowid there.
                vals.append(rowid)
                yield rowid, vals

        def matches(vals: list[Value]) -> bool:
            return all(test(vals[idx]) for (idx, _), test in tests)

        matched = (r for r in rows() if matches(r[1]))
        limit = query.limit
        if query.order_by is None:
            if limit is None:
                chosen: Iterator = matched
            else:
                chosen = _take(matched, limit)
        else:
            # Rows arrive in rowid order and the sort is stable, so ties keep
            # ascending rowid order in both directions (reverse=True preserves
            # the original order of equal elements).
            idx = order_ref[0]  # type: ignore[index]
            ordered = sorted(
                matched,
                key=lambda r: sort_key(r[1][idx]),
                reverse=query.order_by.descending,
            )
            chosen = iter(ordered if limit is None else ordered[:limit])
        for _, vals in chosen:
            yield [vals[i] for i, _ in out_refs]

    @staticmethod
    def _column(table: Table, name: str) -> tuple[int, str]:
        ref = table.resolve(name)
        if ref is None:
            raise QueryError(f"no such column: {name}")
        return ref

    def _condition(
        self, table: Table, cond: Condition
    ) -> tuple[tuple[int, str], Callable[[Value], bool]]:
        ref = self._column(table, cond.column)
        return ref, _make_test(cond.op, apply_affinity(cond.literal, ref[1]))

    def _select_lines(self, query: SelectQuery) -> Iterator[str]:
        for row in self.select_rows(query):
            yield "\t".join(map(format_value, row))

    # -- INDEX --------------------------------------------------------------

    def index_rows(self, index_name: str, literal: Value) -> list[list[Value]]:
        """Rows whose single-column index key equals ``literal``, by rowid."""
        index = self.catalog.index(index_name)
        if index is None or index.sql is None or not index.columns or len(index.columns) != 1:
            raise QueryError(f"cannot use index: {index_name}")
        table = self._usable_table(index.table)
        ref = self._column(table, index.columns[0])
        key = apply_affinity(literal, ref[1])
        if key is None:
            return []
        target = sort_key(key)

        def compare(payload: bytes) -> int:
            k = sort_key(decode_record(payload, 1, (0,))[0])
            return -1 if k < target else (1 if k > target else 0)

        rowids = sorted(
            decode_record(p)[-1] for p in btree.index_equal(self.pager, index.root_page, compare)
        )
        columns = table.columns or ()
        rows = []
        for rowid in rowids:
            payload = btree.find_row(self.pager, table.root_page, rowid)
            if payload is None:
                continue
            vals = decode_record(payload, len(columns))
            if table.rowid_alias is not None:
                vals[table.rowid_alias] = rowid
            rows.append(
                [
                    float(v) if c.affinity == REAL and type(v) is int else v
                    for v, c in zip(vals, columns)
                ]
            )
        return rows

    def _index_lines(self, query: IndexQuery) -> Iterator[str]:
        for row in self.index_rows(query.index, query.literal):
            yield "\t".join(map(format_value, row))


def _take(it: Iterator, n: int) -> Iterator:
    if n <= 0:
        return
    for count, item in enumerate(it, 1):
        yield item
        if count >= n:
            return


_COMPARISONS = {
    "=": operator.eq,
    "!=": operator.ne,
    "<": operator.lt,
    "<=": operator.le,
    ">": operator.gt,
    ">=": operator.ge,
}


def _make_test(op: str, literal: Value) -> Callable[[Value], bool]:
    """Build a predicate over a column value for ``<column> <op> <literal>``."""
    target = sort_key(literal)
    if op == "IS":
        return lambda v: sort_key(v) == target
    if op == "IS NOT":
        return lambda v: sort_key(v) != target
    if literal is None:
        return lambda v: False
    cmp = _COMPARISONS[op]
    return lambda v: v is not None and cmp(sort_key(v), target)
