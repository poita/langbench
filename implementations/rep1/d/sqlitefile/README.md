# sqlitefile

A from-scratch reader for SQLite 3 database files, written in D with no
dependencies beyond the standard library. It parses the on-disk format itself
(pages, B-trees, varints, records, overflow chains, the schema table) and
answers a small query language: `.tables`, `.schema`, `COUNT`, `SELECT` with
`WHERE` / `ORDER BY` / `LIMIT`, and index point lookups. It does not use
SQLite or any code that already understands the format.

The project is a library (`source/sqlitefile/`) plus a thin command-line tool
(`cli/main.d`).

## Building

Requires LDC 1.41 and dub 1.40.

```
./build.sh                                  # or:
dub build -b release --compiler=ldc2        # produces ./sqlitefile
dub test --compiler=ldc2                    # runs the unit tests in tests/
```

## Command-line use

```
sqlitefile <input dir> <output dir>      # or: ./run.sh <input dir> <output dir>
```

The input directory contains one `*.sqlite` file and `queries.txt` (one query
per line). For the *n*-th line the tool writes `NNN.txt` (`001.txt`, …) in the
output directory, which must already exist. A query that cannot be answered
produces a file containing `error`; the exit status is still 0.

| query | result |
|-------|--------|
| `.tables` | user table names, sorted |
| `.schema <table>` | the `CREATE` statements attached to the table |
| `COUNT <table>` | row count |
| `SELECT <cols or *> FROM <table> [WHERE c op lit [AND ...]] [ORDER BY c [ASC\|DESC]] [LIMIT n]` | rows, TAB-separated |
| `INDEX <index> <literal>` | rows found through a single-column index |

Operators are `= != < <= > >= IS` and `IS NOT`; literals are numerals,
`'strings'`, `X'hex'` blobs and `NULL`. Output formatting follows the `sqlite3`
shell (`NULL`, `%.15g` reals with a forced `.0`, uppercase hex blobs). The full
format and query semantics are described in the problem's `SPEC.md`.

## Library layout

| module | responsibility |
|--------|----------------|
| `sqlitefile.bytes` | big-endian integers and varints |
| `sqlitefile.database` | the in-memory database image, header and page access |
| `sqlitefile.btree` | page headers, cells, overflow chains, table scans, rowid seeks, row counts, index search |
| `sqlitefile.record` | lazy record decoding |
| `sqlitefile.value` | `Value` and the SQLite ordering |
| `sqlitefile.affinity` | column affinity and literal conversion |
| `sqlitefile.ddl` | `CREATE TABLE` / `CREATE INDEX` parser |
| `sqlitefile.catalog` | `sqlite_schema` entries, tables and indexes |
| `sqlitefile.query` | query-line parser |
| `sqlitefile.engine` | query execution |
| `sqlitefile.output` | value formatting into a byte buffer |
| `sqlitefile.errors` | exception types |

`import sqlitefile;` brings in everything. The database is read into memory
once and pages are never copied; TEXT and BLOB values are views into the
image.

## Library example

```d
import sqlitefile;
import std.stdio : stdout;

void main()
{
    auto db  = Database.open("people.sqlite");
    auto cat = Catalog.load(db);          // reads sqlite_schema once

    // High level: run a query line, getting the exact bytes of a result file.
    stdout.rawWrite(answer(db, cat, "SELECT name, age FROM people WHERE age > 40 ORDER BY age"));

    // Lower level: walk a table B-tree yourself.
    auto people = cat.table("people");
    RecordReader rr;
    walkTable(db, people.rootPage, (long rowid, const(ubyte)[] payload, bool stable) @safe {
        rr.parse(payload);
        auto name = people.columnValue(rr, people.resolve("name"), rowid);
        // name.bytes is a UTF-8 view into the database image
        return true;                        // false stops the walk
    });
}
```

Errors surface as `SqliteFileException` (`FormatException` for damaged or
unsupported files, `QueryException` for bad queries).

## Layout

```
dub.json            package manifest (configurations: application, library, unittest)
build.sh run.sh     build and run helpers
source/sqlitefile/  the library
cli/main.d          the command-line tool
tests/              unit tests (including a tiny database image builder)
```
