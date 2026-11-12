"""minisql: a small in-memory relational database for a SQL subset.

Quick start::

    from minisql import Database, format_results

    db = Database()
    db.execute("CREATE TABLE t (a INTEGER, b TEXT); INSERT INTO t VALUES (1, 'x');")
    db.query("SELECT a, b FROM t")        # [(1, 'x')]
    print(format_results(db.execute("SELECT * FROM t;")))

Public API:

* :class:`Database` -- ``execute(script)`` and ``query(select)``;
* :class:`StatementResult` -- the outcome of one statement;
* :func:`format_results` -- the textual output format of the CLI;
* :class:`SqlError`, :class:`SqlSyntaxError`, :class:`SqlSemanticError`;
* :class:`Real` -- the REAL value type produced by ``AVG``.
"""

from .database import Database, StatementResult
from .errors import SqlError, SqlSemanticError, SqlSyntaxError
from .output import format_results
from .values import Real

__version__ = "1.0.0"

__all__ = [
    "Database",
    "Real",
    "SqlError",
    "SqlSemanticError",
    "SqlSyntaxError",
    "StatementResult",
    "format_results",
    "__version__",
]
