# minisql

A small in-memory relational database that executes a subset of SQL,
written in Rust with no dependencies outside the standard library.

It supports `CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE` and `SELECT` (one or
two tables, comma or `INNER JOIN ... ON`, `WHERE`, `GROUP BY`, `HAVING`,
`ORDER BY`, `LIMIT`/`OFFSET`, and `COUNT`/`SUM`/`MIN`/`MAX`/`AVG`) over
`INTEGER`, `TEXT` and `NULL` values with three-valued logic. The dialect is a
strict subset of SQLite's; see `problems/minisql/SPEC.md` of the surrounding
repository for the exact definition.

## Build

```sh
cargo build --release     # or ./build.sh
cargo test                # unit, integration and doc tests
```

The binary is `target/release/minisql`; `./run.sh` runs it from any directory.

## Command line

`minisql` reads a SQL script on stdin and writes to stdout; it takes no
arguments.

```sh
$ printf "CREATE TABLE t (k INTEGER, v TEXT);
INSERT INTO t VALUES (2, 'b'), (1, 'a');
SELECT v, k FROM t ORDER BY k;
SELECT * FROM missing;" | ./run.sh
a	1
b	2
-- 2 rows
error
```

- Every `SELECT` prints one tab-separated line per row and then `-- N rows`.
  `NULL` prints as `NULL`; `AVG` results print with two decimals.
- A failing statement (syntax error, unknown table or column, ...) prints
  `error`, has no effect, and execution continues with the next statement.
- `CREATE`, `INSERT`, `UPDATE` and `DELETE` print nothing. The exit status is 0.

## Library

```rust
use minisql::{Database, Output, Value};

let mut db = Database::new();
db.execute("CREATE TABLE emp (name TEXT, salary INTEGER)").unwrap();
db.execute("INSERT INTO emp VALUES ('ann', 120), ('bob', 90), ('cy', NULL)").unwrap();

let Output::Rows(rs) = db
    .execute("SELECT name FROM emp WHERE salary > 100 ORDER BY name")
    .unwrap()
else {
    unreachable!()
};
assert_eq!(rs.rows, vec![vec![Value::text("ann")]]);
print!("{rs}"); // "ann\n-- 1 rows\n"

// Errors are values, and a failing statement leaves the database unchanged.
assert!(db.execute("SELECT nope FROM emp").is_err());

// Whole scripts: one outcome per statement.
let outcomes = db.run_script("SELECT COUNT(*) FROM emp; SELECT;");
assert!(outcomes[0].is_ok() && outcomes[1].is_err());
```

### Module layout

| Module | Responsibility |
| --- | --- |
| `lexer` | text → tokens, statement splitting at `;` |
| `parser`, `ast` | recursive-descent parser and the syntax tree |
| `binder` | name resolution, aggregate/grouping checks → bound tree |
| `eval` | interpreter for bound expressions (3-valued logic, aggregates) |
| `exec` | scans, hash/nested-loop joins, grouping, sorting, UPDATE/DELETE |
| `like` | `LIKE` matcher with a single backtrack point |
| `value`, `table`, `result` | values and their total order, storage, result rendering |
| `db` | `Database`: the entry points |

### Design notes

- Each statement is parsed, bound against the current schema, then executed;
  nothing is cached between statements and there are no indexes.
- A join with at least one cross-table equality is a hash join on all such
  equalities; output order is always nested-loop order.
- `ORDER BY` is one stable sort of all result rows; `LIMIT` is applied after.
- Expressions are interpreted directly from the bound tree.
