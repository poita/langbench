"""Tessera: an embedded, single-file transactional document store.

A write-ahead log, a B+tree primary index, overflow pages for large values,
secondary indexes on document fields and crash recovery, with byte-exact,
fully specified file formats.

Quick start::

    from tessera import Database

    db = Database.open()                       # a fresh in-memory database
    db.put("u1", {"name": "ada", "age": 36})
    db.create_index("age")
    db.find("age >= 30").rows                  # [(b'u1', {...})]
    open("main.tdb", "wb").write(db.db_image())
    open("main.twal", "wb").write(db.wal_image())
"""

from .crc import crc32
from .database import Database, FindResult, IndexInfo, Stat
from .errors import KINDS, TesseraError
from .parser import parse_command, parse_predicate, parse_value
from .query import And, Cmp, Exists, Missing, Not, Or, Plan
from .script import run_script
from .value import render

__all__ = [
    "And", "Cmp", "Database", "Exists", "FindResult", "IndexInfo", "KINDS", "Missing", "Not",
    "Or", "Plan", "Stat", "TesseraError", "crc32", "parse_command", "parse_predicate",
    "parse_value", "render", "run_script",
]
__version__ = "1.0.0"
