# minisql

A small in-memory relational database that executes a subset of SQLite's SQL
dialect. It is a Haskell library (`MiniSQL`) plus a thin command-line tool that
reads a SQL script on stdin and prints the result of every `SELECT`.

Supported SQL: `CREATE TABLE` (`INTEGER`/`TEXT` columns), `INSERT ... VALUES`,
`UPDATE`, `DELETE`, and `SELECT` with `*`, aliases, `WHERE`, one comma join or
`INNER JOIN ... ON` (hash-joined on cross-table equalities), `GROUP BY`,
`HAVING`, `ORDER BY` (aliases, ordinals, expressions), `LIMIT`/`OFFSET`,
`COUNT/SUM/MIN/MAX/AVG`, `LIKE`, `IS [NOT] NULL` and three-valued logic.
Values are dynamically typed (NULL, 64-bit INTEGER, TEXT, and the two-decimal
REAL that `AVG` produces). Everything is implemented from scratch using only
GHC's bundled libraries (`base`, `containers`, `text`, `array`,
`bytestring`).

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the executable to bin/minisql
cabal test          # runs the hspec/QuickCheck test suite
```

## Command-line use

`run.sh` (or `bin/minisql`) reads the script from stdin and writes to stdout.
Each `SELECT` prints one tab-separated line per row followed by `-- N rows`;
a failing statement prints `error`, has no effect, and execution continues.
The exit status is 0.

```sh
$ printf "CREATE TABLE t (k INTEGER, v TEXT);
INSERT INTO t VALUES (2, 'b'), (1, 'a');
SELECT * FROM t ORDER BY k;
SELECT nope FROM t;" | ./run.sh
1	a
2	b
-- 2 rows
error
```

## Library use

```haskell
{-# LANGUAGE OverloadedStrings #-}
import MiniSQL
import qualified Data.Text.Lazy.IO as TL

main :: IO ()
main = do
  -- Render a whole script exactly as the CLI would.
  TL.putStr $ renderScript "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1), (2); SELECT SUM(x) FROM t;"

  -- Or drive it statement by statement and inspect typed results.
  let (db, _) = runScript emptyDatabase "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (40), (2);"
      (_, responses) = runScript db "SELECT SUM(x) FROM t;"
  print responses   -- [ResultRows [[VInt 42]]]
```

A `Database` is an immutable value: `execute :: Database -> Statement ->
Either Error Outcome` returns the new database, so a failing statement cannot
leave partial changes behind.

## Layout

| Module | Responsibility |
| --- | --- |
| `MiniSQL` | Public facade: run scripts, render output |
| `MiniSQL.Lexer` | Tokens, keywords, statement splitting |
| `MiniSQL.Syntax` | Abstract syntax tree |
| `MiniSQL.Parser` | Recursive-descent parser (`parseScript`, `parseExpr`) |
| `MiniSQL.Bound` | Name resolution and semantic checks (binding) |
| `MiniSQL.Eval` | Interpreter for bound expressions, aggregates |
| `MiniSQL.Select` | `SELECT` planning/execution: filter, hash join, grouping, ordering |
| `MiniSQL.Execute` | Statement dispatch, `INSERT`/`UPDATE`/`DELETE`/`CREATE` |
| `MiniSQL.Database` | Tables and the database value |
| `MiniSQL.Value` | Values, the total order, rendering |
| `MiniSQL.Like` | `LIKE` matcher with a single backtrack point |
| `MiniSQL.Hash` | Hash table keyed by value lists (joins, grouping) |
| `MiniSQL.Error` | Error type |

Design notes: every statement is tokenized, parsed, bound against the current
schema and only then executed; nothing is cached or indexed between
statements. Expressions are interpreted from the bound tree. `ORDER BY` is a
single stable sort of all result rows.
