# minisql

A small in-memory relational database written in D. It executes a subset of
SQL (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with
expressions, `LIKE`, one join, `GROUP BY` / `HAVING`, aggregates, `ORDER BY`,
`LIMIT` / `OFFSET`) with SQLite-compatible semantics for dynamic typing,
`NULL` and ordering. The engine is written from scratch and uses only D's
standard library.

The project is a reusable library (`minisql`) plus a thin command-line tool.

## Requirements

* LDC 1.41.0 (`ldc2`) and dub 1.40.0

## Building

```sh
dub build -b release --compiler=ldc2     # or ./build.sh
```

This produces the command-line tool `bin/minisql`.

## Testing

```sh
dub test --compiler=ldc2
```

The tests are ordinary D `unittest` blocks (the standard D approach, so no
external test framework is needed): per-module unit tests next to the code, and
end-to-end script tests in `source/minisql/tests.d`.

## Command line

`minisql` reads a SQL script from standard input, executes the statements in
order and prints the result of every `SELECT`; it takes no arguments and
always exits with status 0. `./run.sh` is a wrapper that finds the binary
relative to itself.

```
$ ./run.sh <<'SQL'
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL);
SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
SQL
eng	2	120.00
ops	1	90.00
-- 2 rows
error
```

Output format: one line per result row with tab-separated values (`NULL`,
decimal integers, bare text, `AVG` results with two decimals), followed by
`-- N rows`. A statement that fails prints the single line `error` and leaves
the database unchanged; execution continues with the next statement. The full
dialect is specified in `SPEC.md` of the problem statement.

## Library

Add the package as a dependency (it exposes a `library` configuration) and
`import minisql;`.

```d
import std.stdio;
import minisql;

void main()
{
    auto db = new Database;

    // Run a whole script, collecting output in the command-line format ...
    string text = db.runScript("
        CREATE TABLE t (k INTEGER, v TEXT);
        INSERT INTO t VALUES (2, 'b'), (1, 'a'), (NULL, 'z');
        SELECT * FROM t ORDER BY k;
    ");
    write(text);   // NULL z / 1 a / 2 b / -- 3 rows

    // ... or execute single statements and inspect typed values.
    auto r = db.execute("SELECT v, k + 1 FROM t WHERE k IS NOT NULL ORDER BY k");
    foreach (row; r.rows)
        writeln(row[0].str, " ", row[1].num);   // a 2 / b 3

    try
        db.execute("SELECT nope FROM t");
    catch (SqlError e)
        writeln("rejected: ", e.msg);
}
```

### API summary

* `Database` — `execute(string)` runs exactly one statement and returns a
  `QueryResult` (`isQuery`, `rows`), throwing `SqlError` on any error with the
  database unchanged; `runScript(string)` runs a script and returns (or
  streams to a sink) the output text; `table(name)` gives read access to a
  `Table`.
* `Value` — a tagged value (`kind` is `null_`, `integer`, `text` or `real_`);
  `compareValues` is the total order used everywhere.
* `SqlError` — the exception for every syntax / binding / execution error.

### Layout

| Module              | Responsibility                                          |
|---------------------|---------------------------------------------------------|
| `minisql.lexer`     | tokens, comments, statement splitting                   |
| `minisql.ast`       | syntax trees                                            |
| `minisql.parser`    | recursive-descent parser                                |
| `minisql.binder`    | resolves columns, checks aggregate / grouping rules     |
| `minisql.expr`      | bound expressions and their tree interpreter            |
| `minisql.select`    | SELECT: hash join, grouping, one stable ORDER BY sort   |
| `minisql.database`  | statement execution, script runner, output formatting   |
| `minisql.table`     | table storage                                           |
| `minisql.value`     | values, three-valued logic, total order, formatting     |
| `minisql.like`      | `LIKE` matcher with a single backtrack point            |

### Design notes

Each statement is lexed, parsed, bound against the current schema (all
semantic checks happen here, before any table changes) and then executed.
Nothing is cached between statements and there are no indexes. WHERE and ON
are split into `AND` conjuncts; conjuncts reading one table filter it before
the join, and cross-table equalities form one composite hash key, so a join
costs O(A + B + M) while still emitting pairs in nested-loop order.
