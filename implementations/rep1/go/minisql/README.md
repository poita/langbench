# minisql

A small in-memory relational database written in Go, using only the standard
library. It executes a strict subset of SQLite's SQL dialect: `CREATE TABLE`,
`INSERT`, `UPDATE`, `DELETE` and `SELECT` with `WHERE`, joins of up to two
tables (comma or `[INNER] JOIN ... ON`), `GROUP BY`, `HAVING`, `ORDER BY`,
`LIMIT`/`OFFSET`, and the aggregates `COUNT`, `SUM`, `MIN`, `MAX` and `AVG`.
Values are dynamically typed (`NULL`, `INTEGER`, `TEXT`, plus `REAL` produced
by `AVG`), with three-valued logic and SQLite-style `LIKE`.

The engine is written from scratch; it does not use SQLite or any other SQL
engine.

## Build

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/minisql (go build -o bin/minisql ./cmd/minisql)
go test ./...       # unit tests
```

## Command-line use

`minisql` reads a SQL script on standard input and prints the result of every
`SELECT` on standard output; `run.sh` is a wrapper that works from any
directory.

```sh
$ printf "CREATE TABLE t (k INTEGER, v TEXT);
INSERT INTO t VALUES (1, 'a'), (2, NULL);
SELECT k, v FROM t ORDER BY k DESC;" | ./run.sh
2	NULL
1	a
-- 2 rows
```

- Each `SELECT` prints one tab-separated line per row (`NULL` for NULL, `REAL`
  with two decimals), then `-- N rows`.
- A statement that fails (syntax error, unknown table, ...) prints `error`,
  has no effect on the database, and execution continues with the next
  statement.
- Other statements print nothing. The exit status is 0 unless I/O fails.

## Library use

```go
package main

import (
	"fmt"
	"os"

	"example.com/minisql"
)

func main() {
	db := minisql.New()

	// Run a whole script, printing output exactly like the CLI does.
	db.RunScript(`
		CREATE TABLE emp (name TEXT, dept TEXT, salary INTEGER);
		INSERT INTO emp VALUES ('ann', 'eng', 120), ('bob', 'ops', 90), ('cy', 'eng', 100);
	`, os.Stdout)

	// Or execute one statement at a time and inspect typed results.
	res, err := db.Exec("SELECT dept, AVG(salary) FROM emp GROUP BY dept")
	if err != nil {
		panic(err) // *minisql.Error with Kind SyntaxError or SemanticError
	}
	for _, row := range res.Rows {
		fmt.Println(row[0].Str(), row[1]) // eng 110.00, ops 90.00
	}
}
```

Public API (see the package documentation for details):

| Item | Purpose |
|------|---------|
| `New() *DB` | create an empty database |
| `(*DB).Exec(sql)` | execute one statement; returns `*Result` (nil unless SELECT) |
| `(*DB).ExecScript(script)` | execute many statements, one `Outcome` each |
| `(*DB).RunScript(script, w)` | execute a script and write CLI-format output |
| `Result.Rows` | `[][]Value` |
| `Value` | `Kind()`, `IsNull()`, `Integer()`, `Str()`, `Hundredths()`, `String()` |
| `Compare(a, b)` | the engine's total order on values |
| `*Error` | `Kind` is `SyntaxError` or `SemanticError` |

A `DB` is not safe for concurrent use.

## Design

Each statement is **parsed** to an AST, **bound** against the current schema
(columns resolved to slot/column indices, aggregates assigned accumulator
slots, all semantic checks run), and then **executed**. Because binding
completes before any table is touched and execution cannot fail, a failing
statement never needs undoing.

Execution is a full scan per statement. Two-table queries filter each table by
its own conjuncts and hash-join on cross-table equalities (arbitrary
expressions are allowed on each side), emitting pairs in nested-loop order.
`GROUP BY` uses a hash map of streaming accumulators; `ORDER BY` is a stable
sort over precomputed keys.

| File | Responsibility |
|------|----------------|
| `value.go`, `output.go` | values, total order, hash-key encoding, formatting |
| `lexer.go` | tokenizer and statement splitting |
| `ast.go`, `parser.go` | AST and recursive-descent parser |
| `bind.go` | name resolution, semantic checks, join planning |
| `eval.go`, `like.go` | expression interpreter, `LIKE` matcher |
| `select.go`, `dml.go` | query / data-modification execution |
| `db.go` | public API |
| `cmd/minisql` | the command-line tool |
