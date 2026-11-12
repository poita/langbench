# minisql

A small in-memory relational database that executes a subset of SQL
(`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with joins over
one or two tables, `WHERE`, `GROUP BY`/`HAVING`, aggregates, `ORDER BY`,
`LIMIT`/`OFFSET`), written in Clojure with no dependencies beyond the standard
library. The dialect is a strict subset of SQLite's; the full behaviour is
specified in `problems/minisql/SPEC.md` of the task this project was built for.

It is a library (`minisql.core`) with a thin command-line tool (`minisql.cli`)
on top: the tool reads a SQL script on stdin and prints the result of each
`SELECT` to stdout.

## Requirements

Clojure 1.12 (the `clojure` CLI) on a recent JDK (developed on Java 27).

## Build

```sh
./build.sh
```

AOT-compiles the CLI into `target/classes` so that `run.sh` starts quickly.
Building is optional: without it, `run.sh` simply loads the sources.

## Command-line use

```sh
./run.sh < script.sql
```

or, without building, `clojure -M:run < script.sql`.

Statements end with `;` (the last one may omit it). Every `SELECT` prints one
tab-separated line per row followed by `-- N rows`; `NULL` prints as `NULL`;
`AVG` results print with two decimals. A statement that fails prints the single
line `error` and leaves the database untouched; execution continues with the next
statement. The exit status is 0.

```console
$ ./run.sh <<'SQL'
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90),
                       (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept ORDER BY dept DESC;
SELECT * FROM nosuch;
SQL
ops	1	90.00
eng	2	120.00
NULL	1	100.00
-- 3 rows
error
```

## Library use

The database is an immutable value; `execute-script` returns the new database
and one result per statement.

```clojure
(require '[minisql.core :as sql])

(let [{:keys [db results]}
      (sql/execute-script (sql/empty-db)
                          "CREATE TABLE t (k INTEGER, v TEXT);
                           INSERT INTO t VALUES (2, 'b'), (1, 'a');
                           SELECT v FROM t ORDER BY k;
                           SELECT nope FROM t;")]
  results
  ;; => [{:type :ok} {:type :ok}
  ;;     {:type :rows :rows [["a"] ["b"]]}
  ;;     {:type :error :message "no such column: nope"}]

  ;; Continue with the returned database, and render results as the CLI does:
  (sql/format-results (:results (sql/execute-script db "SELECT COUNT(*) FROM t;"))))
;; => "2\n-- 1 rows\n"
```

Public API (`minisql.core`):

| function | purpose |
|----------|---------|
| `(empty-db)` | a database with no tables |
| `(execute-script db sql)` | run all statements; `{:db db' :results [...]}` |
| `(execute-tokens db tokens)` | run one lexed statement; `[db' result]` |
| `(run-script sql)` | run on a fresh database, returning the output text |
| `(format-results results)` / `(write-result writer result)` | render results in the CLI's output format |

Results are `{:type :ok}`, `{:type :rows :rows [[v ...] ...]}` or
`{:type :error :message "..."}`. Values are `nil` (NULL), `Long`, `String`, or
`minisql.value.Real` (only produced by `AVG`).

## Layout

| namespace | responsibility |
|-----------|----------------|
| `minisql.lexer` | text -> statements of tokens (comments, strings, `;` splitting) |
| `minisql.parser` | recursive-descent parser: tokens -> syntax tree |
| `minisql.binder` | name resolution against a scope and semantic checks |
| `minisql.eval` | interpreter for bound expressions, three-valued logic, aggregates |
| `minisql.value` | value model, total order, `AVG` rounding, output rendering |
| `minisql.like` | `LIKE` wildcard matcher (single backtrack point, no regex) |
| `minisql.select` | `SELECT` binding and execution: hash join, grouping, ordering |
| `minisql.engine` | executes any statement against a database value |
| `minisql.core` | the public API |
| `minisql.cli` | the command-line tool |

## How queries run

Each statement is lexed, parsed, **bound** against the current schema (every
column resolved, every semantic check run) and only then executed, so a failing
statement never changes anything. Nothing is indexed or cached across
statements. For a two-table query, `WHERE`/`ON` is split into `AND` conjuncts:
those reading one table filter it first, and cross-table equalities form a
composite key for a hash join (expected O(A + B + M)) that still emits pairs in
nested-loop order. Grouping uses a hash map and then sorts the groups; `ORDER BY`
is a single stable sort of all result rows.

## Tests

```sh
clojure -M:test
```

runs the unit, end-to-end and property-based tests (`test/`) with the Cognitect
test-runner and `test.check`.
