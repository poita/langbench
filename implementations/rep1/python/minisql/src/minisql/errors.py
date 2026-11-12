"""Exception types raised by minisql."""

from __future__ import annotations


class SqlError(Exception):
    """Base class for every error a SQL statement can produce.

    A statement that raises ``SqlError`` has no effect on the database.
    """


class SqlSyntaxError(SqlError):
    """The statement does not match the supported SQL grammar."""


class SqlSemanticError(SqlError):
    """The statement is well-formed but invalid against the schema.

    Examples: unknown table or column, ambiguous column, misuse of aggregates,
    wrong number of ``INSERT`` values.
    """
