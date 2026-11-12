# sqlitefile

A from-scratch reader for SQLite 3 database files. It parses the on-disk format
directly — pages, B-trees, varints, records, overflow chains, the schema table
and `CREATE TABLE` / `CREATE INDEX` statements — and answers a small query
language against the file. Pure Python, standard library only; no SQLite
library or binding is used.

## Layout

| module | responsibility |
|---|---|
| `sqlitefile.varint` | SQLite varints |
| `sqlitefile.pager` | database header, pages, payload overflow chains |
| `sqlitefile.btree` | table/index B-tree traversal, row seek, equal-key index search |
| `sqlitefile.record` | record (row/index-entry) decoding |
| `sqlitefile.values` | value ordering, type affinity, text output |
| `sqlitefile.ddl` | tokenizer and `CREATE TABLE` / `CREATE INDEX` parser |
| `sqlitefile.schema` | `sqlite_schema` catalog of tables and indexes |
| `sqlitefile.query` | parser for the query language |
| `sqlitefile.engine` | `Database`: query execution |
| `sqlitefile.cli` | the command-line tool |

## Build

Requires Python 3.12+ (developed on 3.14). There are no dependencies.

```sh
./build.sh          # byte-compiles src/ (a no-op in effect for pure Python)
```

`pyproject.toml` is a standard setuptools project, so `pip install .` also works
if you want the `sqlitefile` console script; it is not needed to run the tool.

## Command line

```sh
./run.sh <input directory> <output directory>
# equivalent: PYTHONPATH=src python3 -m sqlitefile <input dir> <output dir>
```

The input directory holds one `*.sqlite` file and a `queries.txt` with one query
per line. For the *n*-th query, `NNN.txt` (zero-padded to three digits) is
written to the output directory: the result rows, one per line, or the single
line `error` if the query is malformed or names something that does not exist.
The exit status is 0 even when queries fail.

Queries:

```
.tables                          user tables, sorted
.schema <table>                  CREATE statements attached to a table
COUNT <table>
SELECT <cols|*> FROM <table> [WHERE <col> <op> <literal> [AND ...]]
       [ORDER BY <col> [ASC|DESC]] [LIMIT <n>]
INDEX <index-name> <literal>     point lookup through a one-column index
```

Operators are `= != < <= > >= IS` and `IS NOT`; literals are numerals,
`'strings'`, `X'hex'` blobs and `NULL`. Values print like the `sqlite3` shell in
list mode (`NULL`, uppercase-hex blobs, `%.15g` reals that always show a `.`).
The full format and semantics are in the problem's `SPEC.md`.

## Library

```python
from sqlitefile import Database, QueryError

db = Database.open("people.sqlite")

db.table_names()                          # ['people']
db.count("people")                        # 4
db.run("SELECT name, age FROM people WHERE age > 40 ORDER BY name LIMIT 5")
# ['Grace\t45']
db.run("INDEX people_age 45")             # rows found via the index B-tree

try:
    db.run("SELECT nope FROM people")
except QueryError as exc:
    print("bad query:", exc)

# Rows as Python values (None, int, float, str, bytes) instead of text:
from sqlitefile import parse_query
for row in db.select_rows(parse_query("SELECT * FROM people")):
    print(row)
```

`Database` reads the whole file into memory and the catalog once; every query
walks the B-trees from their root pages and nothing else is cached.
`SELECT` is a full table scan, `ORDER BY` sorts all matches before applying
`LIMIT`, `COUNT` sums leaf-page cell counts without decoding records, and
`INDEX` descends the index B-tree to the first matching key and walks the run of
equal entries (interior pages hold entries too).

## Tests

```sh
python3 -m pytest              # unit and integration tests (needs pytest)
```

The tests build small database files byte by byte with a test-only writer
(`tests/dbbuilder.py`), covering all page sizes, overflow chains at the
local-payload thresholds, extreme rowids, multi-level B-trees and indexes whose
equal-key runs span interior cells. The repository-level suite is run with
`python3 run_tests.py sqlitefile -- sqlitefile/run.sh`.
