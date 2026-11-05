# minisql

A small in-memory relational database written in D. It executes a compact SQL
dialect (a strict subset of SQLite's): `CREATE TABLE`, `INSERT`, `UPDATE`,
`DELETE` and `SELECT` with expressions, `LIKE`, joins of up to two tables,
`GROUP BY`/`HAVING` with `COUNT`/`SUM`/`MIN`/`MAX`/`AVG`, `ORDER BY`, `LIMIT`
and `OFFSET`. The engine is written from scratch and uses only D's standard
library (Phobos and druntime).

The project is a reusable library (`source/minisql/`) and a thin
command-line tool on top of it (`app/main.d`).

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces `bin/minisql`. `./run.sh` runs it from any directory.

To run the unit tests (kept in `tests/`, separate from the library sources):

```sh
dub test --compiler=ldc2
```

To build only the library: `dub build --config=library --compiler=ldc2`.

## Command-line use

The tool reads a SQL script on stdin, executes the statements in order and
prints the result of every `SELECT` to stdout. It takes no arguments and exits
with status 0.

```sh
$ ./run.sh <<'SQL'
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL);
SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept ORDER BY dept;
SELECT * FROM nosuch;
SQL
eng	2	120.00
ops	1	90.00
-- 2 rows
error
```

Output format:

* each `SELECT` prints one line per row (values separated by a tab; `NULL`
  for NULL; REAL values, which only `AVG` produces, with two decimals)
  followed by `-- N rows`;
* a statement that fails (syntax error, unknown table or column, ...) prints
  the single line `error`, has no effect on the database, and execution
  continues with the next statement;
* `CREATE`, `INSERT`, `UPDATE` and `DELETE` print nothing.

The exact dialect (lexical rules, comparison order, three-valued logic,
aggregates, ordering and error cases) is defined by the problem specification.

## Library use

```d
import minisql;

void main()
{
    auto db = new Database;

    // Statement by statement; throws SqlException on invalid SQL.
    db.execute("CREATE TABLE t (a INTEGER, b TEXT)");
    db.execute("INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, NULL)");

    Result res = db.execute("SELECT a, b FROM t WHERE a > 1 ORDER BY a DESC");
    foreach (i; 0 .. res.rowCount)
    {
        auto row = res.row(i);               // const(Value)[]
        assert(row[0].kind == Kind.integer);
        // row[0].num is the integer, row[1].str the text (or row[1].isNull)
    }

    // Or run a whole script exactly like the command-line tool does:
    string output = db.run("SELECT COUNT(*) FROM t; SELECT * FROM missing;");
    assert(output == "3\n-- 1 rows\nerror\n");
}
```

Public API (everything is re-exported from `import minisql;`):

| Symbol | Purpose |
| --- | --- |
| `Database` | the catalog and statement pipeline: `execute(sql)` runs one statement and returns a `Result`; `run(script)` runs a script and returns the CLI output; `hasTable(name)` |
| `Result` | rows of a `SELECT` (`isQuery`, `rowCount`, `width`, `row(i)`) |
| `Value`, `Kind` | a NULL / INTEGER / TEXT / REAL value, plus `compareValues`, `toDisplay` |
| `SqlException` | thrown by `execute` for any rejected statement |
| `Table` | table storage (rows in insertion order) |

## Design

A statement goes through three phases; a failure in the first two leaves the
database untouched, and the third cannot fail.

1. **Parse** (`lexer`, `parser`, `ast`): the script is tokenized in one pass,
   split into statements on `;`, and each statement is parsed by recursive
   descent into a syntax tree.
2. **Bind** (`binder`, `plan`): column names are resolved to
   (FROM slot, column index), aggregate calls get accumulator slots, all
   semantic checks run, and literals become ready-made values. `WHERE`/`ON`
   are split into `AND` conjuncts and classified by the tables they read.
3. **Execute** (`executor`, `eval`, `like`, `keytable`): a tree-walking
   interpreter evaluates the bound tree. Single-table queries filter in one
   pass. Two-table queries filter each side by its own conjuncts and then
   hash-join on every cross-table equality (key expressions may be arbitrary),
   emitting pairs in nested-loop order. `GROUP BY` uses a hash table of
   streaming accumulators; `ORDER BY` is a stable sort over precomputed keys.

Text values are slices of the input script, so copying a value never copies
text. `REAL` is stored as an integer number of hundredths.

## Layout

```
dub.sdl             project manifest (configurations: cli, library, unittest)
build.sh run.sh     build and run scripts
source/minisql/     the library, one module per responsibility
app/main.d          the command-line tool
tests/              unit tests (one file per area)
```
