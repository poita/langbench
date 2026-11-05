# sqlitefile

A small Go library and command-line tool that reads a SQLite 3 database file
directly, byte by byte, and answers a handful of queries against it. It has no
dependencies beyond the Go standard library and uses no SQLite library: the
pager, B-tree walker, record decoder, `CREATE TABLE` / `CREATE INDEX` parser and
query evaluator are all implemented here.

The database is read into memory once; pages are never copied, records are
decoded lazily, and TEXT/BLOB values are views into the file image.

Limitations: read-only; UTF-8 databases only; rowid tables only (no
`WITHOUT ROWID`); no auto-vacuum pointer-map pages; no partial or expression
indexes or non-`BINARY` collations; generated columns are not special-cased.

## Build

```
./build.sh          # builds bin/sqlitefile with `go build`
go test ./...       # unit tests
```

Requires Go 1.27 or newer.

## Command-line use

```
./run.sh <input directory> <output directory>
```

The input directory holds exactly one `*.sqlite` file and a `queries.txt` with
one query per line. For the *n*-th query the tool writes `NNN.txt`
(`001.txt`, `002.txt`, ...) into the (existing) output directory. A query that
cannot be answered produces a file containing the single line `error`; the exit
status is still 0.

Query forms (keywords are case-insensitive; the two dot commands are lower case):

| query | output |
|-------|--------|
| `.tables` | user table names, sorted bytewise |
| `.schema <table>` | `sql;` of every schema row whose `tbl_name` is the table, in schema order |
| `COUNT <table>` | the row count |
| `SELECT <cols or *> FROM <table> [WHERE <col> <op> <lit> [AND ...]] [ORDER BY <col> [ASC\|DESC]] [LIMIT <n>]` | tab-separated rows |
| `INDEX <index> <literal>` | rows found through a single-column index, as `SELECT *` |

Operators are `= != < <= > >= IS` and `IS NOT`. Literals are numerals, `'strings'`,
`X'hex'` blobs and `NULL`. `rowid` can be selected, filtered and sorted on.
Values print as the `sqlite3` shell does: `NULL`, decimal integers, reals with
`%.15g` (plus a forced `.0`), text as is, blobs as upper-case hex.

Example `queries.txt`:

```
.tables
SELECT name,height FROM people ORDER BY height DESC LIMIT 2
SELECT name FROM people WHERE age IS NULL
INDEX people_age 45
COUNT people
```

## Library use

```go
package main

import (
	"fmt"
	"log"

	"sqlitefile"
)

func main() {
	db, err := sqlitefile.Open("mini.sqlite")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(db.Tables())

	// Formatted output, exactly as the CLI prints it.
	out, err := db.Exec("SELECT name, age FROM people WHERE age > 40 ORDER BY age DESC", nil)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Print(string(out))

	// Typed rows.
	q, _ := sqlitefile.ParseQuery("SELECT name, height FROM people WHERE age IS NOT NULL")
	res, err := db.Select(q)
	if err != nil {
		log.Fatal(err)
	}
	for _, row := range res.Rows {
		fmt.Println(string(row[0].B), row[1].F)
	}

	// Point lookup through an index.
	rows, _ := db.LookupIndex("people_age", sqlitefile.Int(45))
	fmt.Println(len(rows.Rows))
}
```

## Layout

| file | responsibility |
|------|----------------|
| `pager.go` | database header, page access, payload-overflow thresholds |
| `btree.go` | table/index B-tree walks, rowid seek, index key search, overflow chains |
| `record.go` | varints and lazy record (row) decoding |
| `ddl.go` | tokenizer and `CREATE TABLE` / `CREATE INDEX` parsing, rowid alias |
| `db.go` | opening a database, the schema catalog, `.tables`, `.schema`, `COUNT` |
| `value.go` | values, ordering, type affinity |
| `format.go` | printing values (`%.15g` reals, hex blobs) |
| `query.go` | the query language parser |
| `exec.go` | query planning and execution |
| `cmd/sqlitefile` | the command-line tool |

`DB` is immutable after `Open`, so it is safe for concurrent use. Values
returned from the API may alias the database image and must not be modified.
