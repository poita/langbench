# sqlitefile

A from-scratch reader for SQLite 3 database files, plus a tiny query
evaluator. It parses the file format directly — pages, B-trees, varints,
records, overflow chains, the schema table — using only the Rust standard
library. No SQLite library or binding is involved.

It supports UTF-8 databases with no reserved page space and no auto-vacuum,
rowid tables only, and a deliberately small query language.

## Building

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

The binary is `target/release/sqlitefile`; `./run.sh` is a wrapper for it that
works from any directory.

## Command-line use

```sh
sqlitefile <input dir> <output dir>
```

The input directory holds exactly one `*.sqlite` database and `queries.txt`
with one query per line. For the *n*-th query the tool writes `NNN.txt`
(zero-padded to three digits) into the existing output directory. A query that
fails writes the single line `error`; the exit status is still 0.

### Query language

| query | result |
|-------|--------|
| `.tables` | names of user tables (not `sqlite_*`), sorted bytewise |
| `.schema <table>` | `CREATE` statements (table, indexes, triggers) of the table, each followed by `;` |
| `COUNT <table>` | number of rows |
| `SELECT <cols\|*> FROM <table> [WHERE <cond> [AND <cond>]...] [ORDER BY <col> [ASC\|DESC]] [LIMIT <n>]` | rows, tab-separated |
| `INDEX <index> <literal>` | rows whose indexed column equals the literal, found through the index B-tree |

A condition is `<column> <op> <literal>` with `<op>` one of `=` `!=` `<` `<=`
`>` `>=` `IS` `IS NOT`. Literals are numerals, `'strings'`, `X'hex'` blobs and
`NULL`. `rowid` names the row id. Values print as the `sqlite3` shell prints
them (`NULL`, `%.15g`-style reals with a forced `.0`, uppercase hex blobs).
Ordering, type affinity and the rowid-alias rules follow the SQLite
documentation; see `problems/sqlitefile/SPEC.md` in the parent repository for
the full definition.

Example:

```
$ cat in/queries.txt
.tables
SELECT name,height FROM people ORDER BY height DESC LIMIT 2
INDEX people_age 45
$ sqlitefile in out && cat out/002.txt
Alan	1.8
Grace	1.7
```

## Library use

```rust
use sqlitefile::Engine;

fn main() -> Result<(), sqlitefile::Error> {
    let engine = Engine::open("people.sqlite")?;

    // Run a query; the result is the text the CLI would write.
    print!("{}", engine.execute("SELECT name FROM people WHERE age > 40")?);

    // A failing query becomes "error\n" with `execute_or_error`.
    assert_eq!(engine.execute_or_error("SELECT nope FROM people"), "error\n");

    // Lower-level pieces are public too: the catalog, B-tree walkers, ...
    for row in engine.catalog().rows() {
        println!("{} {}", row.kind, row.name);
    }
    Ok(())
}
```

## Layout

| module | responsibility |
|--------|----------------|
| `pager` | the database file in memory, header validation, page access |
| `btree` | table scan/count/seek and index lookup, payload overflow |
| `record` | record header and value decoding |
| `varint` | SQLite varints |
| `ddl` | `CREATE TABLE` / `CREATE INDEX` parsing, rowid alias detection |
| `catalog` | schema rows, tables, columns, indexes |
| `value` | values, affinity, ordering, output formatting |
| `query` | query-language parser |
| `engine` | query execution |

`SELECT` is a full scan of the table B-tree; `COUNT` sums leaf cell counts;
`INDEX` does a binary search per level, walks the equal entries (including those
in interior pages) and fetches each row by rowid. Only the schema catalog is
kept between queries.

## Tests

`tests/common` contains a small SQLite file *writer* (table and index B-trees,
overflow chains, a schema page) used by `tests/queries.rs` to build fixtures in
memory; `tests/cli.rs` runs the binary end to end. Unit tests live next to the
code they test.
