# sqlitefile

A small, dependency-free Go library and command-line tool that reads a SQLite 3
database file **directly, byte by byte** — no SQLite library, binding or driver —
and answers a handful of queries against it.

It understands the on-disk format (pages, B-trees, varints, records, payload
overflow chains), parses `CREATE TABLE` / `CREATE INDEX` statements from the
schema, and runs a tiny query language. The database is opened read-only.

## Build

Requires Go 1.27.1 and nothing else (standard library only).

```sh
./build.sh          # builds bin/sqlitefile
go test ./...       # runs the unit and integration tests
```

`build.sh` is `go build -o bin/sqlitefile ./cmd/sqlitefile` with the default
optimisation settings; `run.sh` runs the resulting binary from any directory.

## Command-line tool

```
sqlitefile <input directory> <output directory>
```

The input directory holds exactly one `*.sqlite` file and `queries.txt` with one
query per line. For the *n*-th query the tool writes `NNN.txt` (zero-padded to
three digits) into the existing output directory: one output line per result
row, or the single line `error` if the query fails. The exit status is 0 even
when individual queries fail; it is non-zero only for problems such as a missing
`queries.txt` or an unwritable output directory.

### Queries

Keywords are case-insensitive; names are bare identifiers resolved
case-insensitively.

| query | result |
|-------|--------|
| `.tables` | names of the user tables (not `sqlite_*`), bytewise sorted |
| `.schema <table>` | the `CREATE` statements (table, indexes, triggers) of that table, each followed by `;` |
| `COUNT <table>` | the number of rows |
| `SELECT <cols\|*> FROM <table> [WHERE <cond> [AND <cond>]...] [ORDER BY <col> [ASC\|DESC]] [LIMIT n]` | rows, tab-separated |
| `INDEX <index> <literal>` | rows whose indexed column equals the literal, found through the index B-tree |

A condition is `<column> <op> <literal>` with `<op>` one of `=` `!=` `<` `<=`
`>` `>=` `IS` `IS NOT`. Literals are numbers (`42`, `-1.5e3`), strings
(`'it''s'`), blobs (`X'00ff'`) and `NULL`. `rowid` names the row id. Values print as
the `sqlite3` shell does in list mode: `NULL`, decimal integers, reals with
15 significant digits (`1.0`, `0.1`, `1.0e+20`), text as is, blobs as upper-case hex.

Example:

```
$ cat in/queries.txt
.tables
SELECT name,height FROM people ORDER BY height DESC LIMIT 2
INDEX people_age 45
SELECT nope FROM people
$ ./run.sh in out && head out/*.txt
==> out/001.txt <==
people
==> out/002.txt <==
Alan	1.8
Grace	1.7
==> out/003.txt <==
2	Grace	45	1.7	NULL
==> out/004.txt <==
error
```

## Library

```go
package main

import (
	"fmt"
	"log"

	"sqlitefile"
)

func main() {
	db, err := sqlitefile.Open("people.sqlite")
	if err != nil {
		log.Fatal(err)
	}
	lines, err := db.Exec("SELECT name FROM people WHERE age > 30 ORDER BY name DESC")
	if err != nil {
		log.Fatal(err) // malformed query, unknown table/column, ...
	}
	for _, l := range lines {
		fmt.Println(l)
	}
}
```

### Packages

| package | responsibility |
|---------|----------------|
| `sqlitefile` | `Open`/`OpenBytes` a database and `Exec` query lines |
| `sqlitefile/value` | storage classes, ordering (`Compare`), type affinity, output formatting |
| `sqlitefile/record` | varints and the record (row) format |
| `sqlitefile/btree` | pager, B-tree pages, overflow chains; table scan/count/seek and index search |
| `sqlitefile/schema` | `CREATE TABLE`/`CREATE INDEX` parsing and the `sqlite_schema` catalog |
| `sqlitefile/query` | parser for the query language |

The lower-level packages are usable on their own, for example to walk a table
B-tree with `btree.Pager.ScanTable` and decode rows with `record.Parse`.

### Design

- `SELECT` is a full in-order scan of the table B-tree; with `ORDER BY` all
  matching rows are sorted (stably, so ties are in rowid order) before `LIMIT`.
- `COUNT` sums the leaf pages' cell counts and decodes no records.
- `INDEX` binary-searches the index B-tree (interior cells hold entries too),
  walks only the run of equal keys, then fetches each row by rowid.
- The only state kept between queries is the file image and the schema catalog.
- Malformed database content yields errors (`btree.ErrCorrupt`), not panics.

### Scope

Supported: UTF-8 databases, rowid tables (not `WITHOUT ROWID`), reserved page
space per page, any valid page size. Not supported: writing, UTF-16 databases, joins,
expression or partial indexes, non-`BINARY` collations.

## Tests

`go test ./...` runs table-driven unit tests for every package, a hand-built
B-tree image test (overflow chains, negative rowids, entries in interior index
cells, cycle detection), and integration tests against the fixture databases in
`testdata/` (regenerate with `testdata/gen.sh`, which needs the `sqlite3` shell).
