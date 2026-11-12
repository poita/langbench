# sqlitefile

A read-only SQLite 3 database reader written in Clojure. It parses the file
format itself — pager, B-trees, varints, records, overflow chains, the
`CREATE TABLE` / `CREATE INDEX` statements in the schema — and answers a small
query language. It uses only the Clojure standard library: no SQLite library,
JDBC driver or other code that already understands the format.

The project has two parts:

* a **library** (`sqlitefile.core`) with a small public API, and
* a thin **command-line tool** (`sqlitefile.cli`) that answers a file of
  queries, one result file per query.

## Requirements

Clojure 1.12.6 (the `clojure` CLI) on a recent JDK (developed on Java 27).

## Build

```sh
./build.sh
```

This AOT-compiles the command-line tool into `target/classes` and records the
classpath in `target/classpath`. `./run.sh` works from any directory.

## Command-line usage

```sh
./run.sh <input directory> <output directory>
```

The input directory holds exactly one `*.sqlite` file and `queries.txt` (one
query per line). For the *n*-th query the tool writes `NNN.txt` (`001.txt`,
`002.txt`, …) to the output directory; a query that fails writes the single
line `error`. The exit status is 0 even when queries fail.

| query | result |
|-------|--------|
| `.tables` | names of user tables, sorted bytewise (views and `sqlite_*` tables excluded) |
| `.schema <table>` | the `CREATE` statements attached to the table (including its indexes and triggers), each followed by `;` |
| `COUNT <table>` | the number of rows, from the B-tree's leaf cell counts |
| `SELECT <cols\|*> FROM <table> [WHERE <col> <op> <lit> [AND …]] [ORDER BY <col> [ASC\|DESC]] [LIMIT <n>]` | rows, tab-separated; `<op>` is one of `= != < <= > >= IS` or `IS NOT`; the column may be `rowid` |
| `INDEX <index> <literal>` | the rows whose value in the single-column index equals the literal, found through the index B-tree |

Values print as the `sqlite3` shell does: `NULL`, integers in decimal, reals
with `%.15g` semantics (always with a fractional part: `1.0`, `1.0e+15`),
text as is, blobs in uppercase hex. The full format is in the problem's
`SPEC.md`.

## Library usage

```clojure
(require '[sqlitefile.core :as sf])

(def db (sf/open "people.sqlite"))

(sf/tables db)                  ;=> ["people"]
(sf/columns db "people")        ;=> ["id" "name" "age" "height" "photo"]
(sf/count-rows db "people")     ;=> 4

;; rows are vectors of plain values: nil, Long, Double, String, byte[]
(sf/select db "people" {:columns  ["name" "height"]
                        :where    [["age" :> 40]]
                        :order-by ["height" :desc]
                        :limit    2})
;=> [["Grace" 1.7]]

(sf/index-lookup db "people_age" 45)   ; walks the index B-tree
(sf/query db "SELECT name FROM people WHERE age IS NULL")  ;=> "Alan\n"
```

Errors are `ExceptionInfo`s whose `ex-data` has a `:type` of
`:sqlitefile/corrupt`, `:sqlitefile/syntax` or `:sqlitefile/query`.

### Modules

| namespace | responsibility |
|-----------|----------------|
| `sqlitefile.core` | public API |
| `sqlitefile.pager` | file header, page addressing, payload/overflow assembly |
| `sqlitefile.btree` | table scan, row count, rowid seek, index search |
| `sqlitefile.record` | record (row / index entry) decoding |
| `sqlitefile.value` | ordering, affinity, value formatting |
| `sqlitefile.ddl` | `CREATE TABLE` / `CREATE INDEX` parsing, rowid alias detection |
| `sqlitefile.schema` | the catalog built from `sqlite_schema` |
| `sqlitefile.query` | query-language parser |
| `sqlitefile.exec` | query execution and result formatting |
| `sqlitefile.cli` | the command-line tool |
| `sqlitefile.bytes` | big-endian integers and varints |

The whole file is read into memory. Only the catalog is kept between queries.

## Tests

```sh
clojure -X:test
```

Runs the Cognitect test-runner over `test/`: unit and property
(`test.check`) tests for varints, records, ordering and formatting; DDL and
query parser tests; end-to-end tests against database images built in memory
by `test/sqlitefile/fixture.clj` (multi-level table and index B-trees,
overflow chains, interior index entries); CLI tests; and, when the
`../problems/sqlitefile/tests` corpus is present, every corpus case.
