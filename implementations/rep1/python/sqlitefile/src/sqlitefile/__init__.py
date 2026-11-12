"""sqlitefile: read SQLite 3 database files byte by byte and query them.

Typical use::

    from sqlitefile import Database

    db = Database.open("people.sqlite")
    db.table_names()                      # ['people']
    db.run("SELECT name FROM people WHERE age > 40 ORDER BY name")
    db.run("COUNT people")                # ['4']

No SQLite library is involved: the file format is decoded directly.
"""

from .engine import Database
from .errors import FormatError, QueryError, SqliteFileError
from .query import parse_query
from .values import format_value

__all__ = [
    "Database",
    "FormatError",
    "QueryError",
    "SqliteFileError",
    "format_value",
    "parse_query",
]
__version__ = "0.1.0"
