"""The public :class:`Database` class."""

from __future__ import annotations

from dataclasses import dataclass

from .binder import bind
from .errors import SqlError
from .executor import Row, execute
from .lexer import split_statements
from .parser import parse_statement
from .table import Table


@dataclass(frozen=True, slots=True)
class StatementResult:
    """Outcome of one statement of a script.

    ``rows`` holds the output rows of a ``SELECT`` (``None`` for other
    statements); ``error`` is set instead if the statement failed.
    """

    rows: list[Row] | None = None
    error: SqlError | None = None

    @property
    def ok(self) -> bool:
        return self.error is None


class Database:
    """An in-memory database executing minisql's SQL dialect.

    >>> db = Database()
    >>> db.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (2);")
    [StatementResult(rows=None, error=None), StatementResult(rows=None, error=None)]
    >>> db.query("SELECT SUM(a) FROM t")
    [(3,)]
    """

    def __init__(self) -> None:
        self._tables: dict[str, Table] = {}

    def execute(self, script: str) -> list[StatementResult]:
        """Run every statement of ``script`` in order.

        A failing statement yields a :class:`StatementResult` carrying its
        error and leaves the database unchanged; execution continues with the
        next statement. Returns one result per (non-empty) statement.
        """
        results = []
        for tokens in split_statements(script):
            try:
                plan = bind(parse_statement(tokens), self._tables)
                results.append(StatementResult(rows=execute(plan, self._tables)))
            except SqlError as exc:
                results.append(StatementResult(error=exc))
        return results

    def query(self, sql: str) -> list[Row]:
        """Run exactly one ``SELECT`` and return its rows.

        Raises :class:`SqlError` if the statement is invalid, or
        :class:`ValueError` if ``sql`` is not a single ``SELECT``.
        """
        results = self.execute(sql)
        if len(results) != 1 or (results[0].ok and results[0].rows is None):
            raise ValueError("query() expects exactly one SELECT statement")
        if results[0].error is not None:
            raise results[0].error
        assert results[0].rows is not None
        return results[0].rows

    def table_names(self) -> list[str]:
        """Names of all tables, in creation order (lower-case)."""
        return list(self._tables)
