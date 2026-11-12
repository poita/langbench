# minisql

A small in-memory relational database that executes a subset of SQL
(`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with `WHERE`,
inner/comma joins of up to two tables, `GROUP BY`/`HAVING`, aggregates,
`ORDER BY`, `LIMIT`/`OFFSET`, `LIKE`, three-valued logic). It is written from
scratch in C++17 with no dependencies beyond the standard library; the
dialect is a strict subset of SQLite's.

## Layout

| Path | Contents |
|------|----------|
| `include/minisql/` | Public headers: `value.hpp`, `lexer.hpp`, `ast.hpp`, `parser.hpp`, `like.hpp`, `database.hpp`, `error.hpp`, umbrella `minisql.hpp` |
| `src/` | Implementation: lexer, recursive-descent parser, binder (name resolution and semantic checks), evaluator, SELECT executor (filter push-down, hash join, grouping, stable sort), DML executors |
| `cli/main.cpp` | The command-line tool |
| `tests/` | GoogleTest unit tests |

Every statement is parsed, bound against the current schema, and only then
executed, so a failing statement never changes the database. Equality
conditions between the two joined tables are executed as a hash join (output
stays in nested-loop order); everything else scans.

## Build

Requires a C++17 compiler and CMake ≥ 3.20 (GoogleTest is needed only for the tests).

```sh
./build.sh                 # Release build into ./build
ctest --test-dir build     # run the unit tests
```

## Command-line tool

`minisql` reads a SQL script on stdin and prints the result of each `SELECT`:
one tab-separated line per row followed by `-- N rows`. A statement that fails
prints `error` and has no effect; execution continues with the next one. The
exit status is 0.

```sh
$ printf "CREATE TABLE t (k INTEGER, v TEXT);
INSERT INTO t VALUES (2,'b'),(1,'a');
SELECT * FROM t ORDER BY k;" | ./run.sh
1	a
2	b
-- 2 rows
```

## Library

```cpp
#include <iostream>
#include "minisql/minisql.hpp"

int main() {
  minisql::Database db;
  db.execute("CREATE TABLE emp (name TEXT, salary INTEGER)");
  db.execute("INSERT INTO emp VALUES ('ann', 120), ('bob', 90)");

  try {
    minisql::ExecResult r = db.execute("SELECT name, salary FROM emp ORDER BY salary DESC");
    for (const minisql::Row& row : r.rows)
      std::cout << minisql::to_string(row[0]) << ": " << minisql::to_string(row[1]) << "\n";
    db.execute("SELECT nope FROM emp");  // throws minisql::Error
  } catch (const minisql::Error& e) {
    std::cerr << "error: " << e.what() << "\n";
  }

  // Or run a whole script, formatted exactly like the CLI does:
  std::cout << db.run_script("SELECT COUNT(*) FROM emp;");
}
```

Link against the `minisql::minisql` CMake target (`add_subdirectory(minisql)`).
