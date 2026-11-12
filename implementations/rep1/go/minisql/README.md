# minisql

A small in-memory relational database written in Go, using only the standard
library. It executes a subset of SQL (a strict subset of SQLite's dialect):
`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with comma/`INNER`
joins of up to two tables, `WHERE`, `GROUP BY`/`HAVING`, the aggregates
`COUNT SUM MIN MAX AVG`, `ORDER BY`, `LIMIT`/`OFFSET`, `LIKE`, and
three-valued logic over `NULL`, 64-bit integers and text.

The engine is written from scratch: tokenizer, recursive-descent parser,
binder (name resolution and semantic checks) and an interpreter over the bound
expression tree. Equality joins use a hash join that preserves nested-loop
output order; `GROUP BY` uses a hash map; `ORDER BY` is one stable sort.

## Layout

| Package            | Responsibility                                              |
|--------------------|-------------------------------------------------------------|
| `minisql`          | Public facade: `DB`, `Exec`, `ExecScript`, `RunScript`      |
| `minisql/value`    | Dynamic values, the total ordering, `AVG` rounding, `LIKE`  |
| `minisql/syntax`   | Lexer, statement splitter, AST, parser                      |
| `minisql/engine`   | Tables, binding, execution (scans, joins, grouping, sorting) |
| `cmd/minisql`      | Command-line tool                                           |

## Build

```
./build.sh          # runs: go build -o bin/minisql ./cmd/minisql
```

Requires Go 1.27 or newer. Run the tests with `go test ./...`.

## Command-line use

The program reads a whole SQL script on standard input and writes to standard
output; it takes no arguments (`./run.sh` just launches `bin/minisql`).

```
$ ./run.sh <<'SQL'
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1,'ann','eng',120), (2,'bob','ops',90), (3,'cy','eng',NULL);
SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept ORDER BY dept;
SELECT * FROM nosuch;
SQL
eng	2	120.00
ops	1	90.00
-- 2 rows
error
```

For each `SELECT` it prints one line per row (values separated by a tab, `NULL`
for NULL, reals with two decimals) followed by `-- N rows`. A statement that
fails prints `error`, has no effect on the database, and execution continues
with the next statement. The exit status is 0 unless reading stdin or writing
stdout fails.

## Library use

```go
package main

import (
	"fmt"
	"os"

	"minisql"
)

func main() {
	db := minisql.New()
	db.Exec("CREATE TABLE t (a INTEGER, b TEXT)")
	db.Exec("INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, NULL)")

	res, err := db.Exec("SELECT a, b FROM t WHERE a >= 2 ORDER BY a DESC")
	if err != nil {
		panic(err)
	}
	for _, row := range res.Rows {
		fmt.Println(row[0], row[1]) // minisql.Value implements fmt.Stringer
	}

	// Run a whole script and print results in the command-line format.
	db.RunScript("SELECT COUNT(*) FROM t;", os.Stdout)
}
```

`DB.Exec` runs one statement and returns the `*Result` of a `SELECT` (nil for
other statements). `DB.ExecScript` runs a script and returns one `Outcome`
(result or error) per statement. See the package documentation
(`go doc minisql`) for details.
