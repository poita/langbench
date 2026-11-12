"""The catalog: ``sqlite_schema`` rows parsed into tables and indexes (§1.10, Part 2)."""

from __future__ import annotations

from dataclasses import dataclass

from . import btree
from .ddl import ColumnDef, parse_create_index, parse_create_table
from .errors import FormatError, SqliteFileError
from .pager import Pager
from .record import decode_record
from .values import INTEGER, ascii_lower

#: Pseudo-column name that refers to the rowid.
ROWID = "rowid"


@dataclass(frozen=True, slots=True)
class SchemaRow:
    """One row of the ``sqlite_schema`` table."""

    rowid: int
    type: str | None
    name: str | None
    tbl_name: str | None
    rootpage: int | None
    sql: str | None


@dataclass(frozen=True, slots=True)
class Table:
    name: str
    root_page: int
    sql: str | None
    #: ``None`` when the ``CREATE TABLE`` text could not be parsed.
    columns: tuple[ColumnDef, ...] | None
    rowid_alias: int | None

    def column_index(self, name: str) -> int | None:
        """Index of a column by case-insensitive name, or ``None``."""
        folded = ascii_lower(name)
        for i, col in enumerate(self.columns or ()):
            if ascii_lower(col.name) == folded:
                return i
        return None

    def resolve(self, name: str) -> tuple[int, str] | None:
        """Resolve a column reference to ``(index, affinity)``.

        The index is ``-1`` for the ``rowid`` pseudo-column, which has INTEGER
        affinity. A real column named ``rowid`` takes precedence.
        """
        idx = self.column_index(name)
        if idx is not None:
            return idx, (self.columns or ())[idx].affinity
        if ascii_lower(name) == ROWID:
            return -1, INTEGER
        return None


@dataclass(frozen=True, slots=True)
class Index:
    name: str
    table: str
    root_page: int
    sql: str | None
    #: Indexed column names; ``None`` when the statement could not be parsed.
    columns: tuple[str, ...] | None


class Catalog:
    """Everything the schema table says, indexed for case-insensitive lookup."""

    def __init__(self, rows: list[SchemaRow]) -> None:
        self.rows = rows
        self._tables: dict[str, Table] = {}
        self._indexes: dict[str, Index] = {}
        for row in rows:
            if row.name is None:
                continue
            key = ascii_lower(row.name)
            if row.type == "table":
                self._tables.setdefault(key, self._make_table(row))
            elif row.type == "index":
                self._indexes.setdefault(key, self._make_index(row))

    @classmethod
    def read(cls, pager: Pager) -> "Catalog":
        """Read page 1, the root of the schema table, and parse it."""
        rows = []
        for rowid, payload in btree.iter_table(pager, 1):
            v = decode_record(payload, 5)
            rows.append(SchemaRow(rowid, *_schema_fields(v)))
        return cls(rows)

    @staticmethod
    def _make_table(row: SchemaRow) -> Table:
        columns = alias = None
        if row.sql is not None:
            try:
                definition = parse_create_table(row.sql)
                columns, alias = definition.columns, definition.rowid_alias
            except SqliteFileError:
                pass
        return Table(row.name or "", row.rootpage or 0, row.sql, columns, alias)

    @staticmethod
    def _make_index(row: SchemaRow) -> Index:
        columns = None
        if row.sql is not None:
            try:
                columns = parse_create_index(row.sql).columns
            except SqliteFileError:
                pass
        return Index(row.name or "", row.tbl_name or "", row.rootpage or 0, row.sql, columns)

    def table(self, name: str) -> Table | None:
        """The table called ``name`` (ASCII case-insensitive), or ``None``."""
        return self._tables.get(ascii_lower(name))

    def index(self, name: str) -> Index | None:
        """The index called ``name`` (ASCII case-insensitive), or ``None``."""
        return self._indexes.get(ascii_lower(name))


def _schema_fields(v: list) -> tuple:
    type_, name, tbl_name, rootpage, sql = v[:5]
    for field in (type_, name, tbl_name, sql):
        if field is not None and not isinstance(field, str):
            raise FormatError("malformed sqlite_schema row")
    if rootpage is not None and not isinstance(rootpage, int):
        raise FormatError("malformed sqlite_schema row")
    return type_, name, tbl_name, rootpage, sql
