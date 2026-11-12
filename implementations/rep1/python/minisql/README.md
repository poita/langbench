# minisql

A small in-memory relational database that executes a subset of SQL
(`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with joins on two
tables, `WHERE`, `GROUP BY`/`HAVING`, aggregates, `ORDER BY` and
`LIMIT`/`OFFSET`). The dialect is a strict subset of SQLite's and is written out
in full in the problem's `SPEC.md`. It is pure Python with no dependencies and
the engine is written from scratch (no `sqlite3`).

## Build

```sh
./build.sh          # byte-compiles the package; there is nothing else to build
```

Python 3.12+ is required (developed on 3.14). Tests need `pytest`.

## Command line

`run.sh` reads a SQL script on stdin and prints the result of every `SELECT`:

```sh
echo "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(2); SELECT SUM(a) FROM t;" | ./run.sh
# 3
# -- 1 rows
```

Each `SELECT` prints one tab-separated line per row followed by `-- N rows`.
`NULL` prints as `NULL`, `AVG` results with two decimals. A statement that
fails prints a single line `error`, has no effect, and execution continues.
The exit status is 0 once all input is processed. (`run.sh` is equivalent to
`PYTHONPATH=src python3 -m minisql`; after `pip install .` the command is
`minisql`.)

## Library

```python
from minisql import Database, SqlError, format_results

db = Database()
db.execute("""
    CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
    INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90),
                           (3, 'cy', 'eng', NULL);
""")

db.query("SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept")
# [('eng', 2, Real(120.00)), ('ops', 1, Real(90.00))]

try:
    db.query("SELECT nosuch FROM emp")
except SqlError as exc:
    print("failed:", exc)

# Run a whole script and render it exactly as the CLI does:
print(format_results(db.execute("SELECT name FROM emp ORDER BY salary DESC;")))
```

* `Database.execute(script)` runs every statement and returns one
  `StatementResult` (`rows`, `error`, `ok`) each; failures do not raise.
* `Database.query(select)` runs one `SELECT` and returns a list of tuples
  (`None`, `int`, `str` or `Real`), raising `SqlError` on failure.
* `format_results(results)` renders results in the CLI's output format.

## Layout

| Module | Responsibility |
| --- | --- |
| `lexer.py` | tokens, comments, statement splitting |
| `parser.py`, `syntax.py` | recursive-descent parser and syntax tree |
| `binder.py`, `plan.py` | name resolution, semantic checks, plans |
| `expr.py`, `values.py`, `like.py` | expression interpreter, value ordering, LIKE |
| `executor.py` | scans, hash joins, grouping, stable sorting |
| `database.py`, `table.py`, `output.py` | public `Database`, storage, output format |
| `cli.py` | the command-line tool |

Statements are parsed, bound (every semantic check runs before anything
changes), then executed. Cross-table equalities in a two-table `FROM` are run
as a hash join that still emits pairs in nested-loop order; everything else is
a scan. Nothing is cached between statements.

## Tests

```sh
python3 -m pytest          # from this directory
```
