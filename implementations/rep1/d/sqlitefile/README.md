# sqlitefile

A from-scratch reader for SQLite 3 database files, written in D. It parses the
on-disk format directly (pages, B-trees, varints, records, overflow chains) and
answers a small set of queries without any SQLite library. The code is split
into a reusable library (`sqlitefile`) and a thin command-line tool on top.

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0). Only the D
standard library and druntime are used.

```sh
dub build -b release --compiler=ldc2     # builds ./sqlitefile (the CLI)
# or
./build.sh
```

Run the unit tests (from the package root; they read fixtures in `tests/data`):

```sh
dub test --compiler=ldc2
tests/cli_test.sh        # end-to-end check of the built CLI (uses sqlite3 if installed)
```

`dub.sdl` defines two configurations: `cli` (the executable, default) and
`library` (what other packages depend on).

## Command-line use

```
sqlitefile <input directory> <output directory>
```

The input directory contains exactly one `*.sqlite` file and a `queries.txt`
with one query per line. For the *n*-th query the tool writes `NNN.txt`
(`001.txt`, `002.txt`, …) into the existing output directory; a failing query
produces a file containing the single line `error`. The exit status is 0 even
when individual queries fail. `run.sh <in> <out>` is a wrapper that locates the
binary relative to itself.

Query language:

| query | result |
|-------|--------|
| `.tables` | user table names, sorted bytewise (no `sqlite_*`, no views) |
| `.schema <table>` | the stored `CREATE` statements (table, indexes, triggers) of that table, each followed by `;` |
| `COUNT <table>` | number of rows |
| `SELECT <*\|col,...> FROM <table> [WHERE c op lit [AND ...]] [ORDER BY col [ASC\|DESC]] [LIMIT n]` | rows, tab-separated; `rowid` is a valid column |
| `INDEX <index> <literal>` | rows whose indexed (single) column equals the literal, found through the index B-tree |

Operators are `= != < <= > >= IS` and `IS NOT`; literals are numerals,
`'strings'`, `X'hex'` blobs and `NULL`. Values print as the `sqlite3` shell
does (`NULL`, decimal integers, `%.15g` reals with a forced `.0`, uppercase hex
blobs). See `SPEC.md` of the task for the exact rules.

## Library layout

| module | responsibility |
|--------|----------------|
| `sqlitefile.database` | the pager: file bytes, header, page access |
| `sqlitefile.btree` | page/cell decoding, overflow chains, table scan, row count, rowid seek, index equality search |
| `sqlitefile.record` | record decoding by serial type |
| `sqlitefile.value`, `.affinity`, `.numeric`, `.render` | value model and ordering, column affinity, numeric constants, output formatting |
| `sqlitefile.ddl`, `.schema` | tokenizer and `CREATE TABLE` / `CREATE INDEX` parsers; the catalog |
| `sqlitefile.query`, `.engine` | query parser and executor |
| `sqlitefile.bytes`, `.errors` | bounds-checked integer/varint reading; exception types |

`import sqlitefile;` publicly imports all of them.

## Library example

```d
import std.stdio : write;
import sqlitefile;

void main()
{
    auto db = Database.open("people.sqlite");
    auto engine = new Engine(db);                 // reads sqlite_schema once

    // Whole queries, as the CLI runs them:
    write(cast(string) engine.execute("SELECT name FROM people WHERE age > 40"));

    // Or use the lower layers directly: walk a table B-tree and decode rows.
    const table = engine.catalog.findTable("people");
    auto row = new Value[table.columns.length];
    walkTable(db, table.rootPage, (long rowid, const(ubyte)[] payload) {
        table.decodeRow(rowid, payload, row);
        write(rowid, " ", formatValue(row[1]), "\n");
        return true;                              // false stops the scan
    });
}
```

`Engine.execute` throws a `SqliteFileException` subclass (`QueryException`,
`FormatException`, …) when a query cannot be answered; `executeOrError` returns
`error\n` instead.

## Design notes

The whole file is read into memory; TEXT and BLOB values are slices into it, so
scanning does not copy. `SELECT` always scans the table B-tree (stopping early
when `LIMIT` is satisfied and there is no `ORDER BY`), `COUNT` sums leaf-page
cell counts without decoding records, and `INDEX` binary-searches the index
B-tree (interior pages hold entries too) and then fetches each row by rowid.
Only the catalog is kept between queries.
