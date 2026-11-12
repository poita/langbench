"""Exception types raised by the library."""

from __future__ import annotations


class SqliteFileError(Exception):
    """Base class for every error raised deliberately by this library."""


class FormatError(SqliteFileError):
    """The database file is malformed or uses an unsupported feature."""


class QueryError(SqliteFileError):
    """A query is malformed or refers to something that does not exist."""
