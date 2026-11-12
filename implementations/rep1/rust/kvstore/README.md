# Tessera

Tessera is an embedded, single-file transactional document store written in
Rust with no dependencies beyond the standard library. It has:

- a write-ahead log (`main.twal`) in front of a page file (`main.tdb`), with
  crash recovery and checkpointing;
- a B+tree primary index over canonical 1 KiB pages, with overflow chains for
  documents up to 64 KiB;
- secondary indexes on document field paths (up to 16);
- explicit and implicit transactions;
- a small command language (`put`, `get`, `scan`, `find`, `create index`, …).

The file format is fully deterministic: the same commands always produce
byte-identical `main.tdb` and `main.twal` files.

The project is a library (`tessera`) plus a thin command-line tool
(`kvstore`). The format and the command language are specified in the
problem's `SPEC.md`.

## Building

Requires Rust 1.80 or newer (developed with 1.96).

```sh
./build.sh            # cargo build --release  ->  target/release/kvstore
cargo test            # unit, integration and doc tests
```

## Command-line tool

```
kvstore <input dir> <output dir>      # or: ./run.sh <input dir> <output dir>
```

The input directory contains `commands.txt` (one command per line) and,
optionally, an existing `main.tdb` and `main.twal`. The tool opens the
database (recovering from the log if there is one), runs every command, and
writes three files to the output directory:

| File | Content |
|---|---|
| `results.txt` | one result block per command line |
| `main.tdb` | the database file after the script |
| `main.twal` | the write-ahead log after the script |

A transaction still open at the end of the script is rolled back. No
checkpoint happens unless the script asks for one (or the log reaches
256 KiB). Exit status is 0 unless the files cannot be read or written;
failing *commands* are reported in `results.txt`, not through the exit status.

Example:

```
$ cat in/commands.txt
put "u1" {name:"ada", age:36}
put "u2" {name:"bob", age:29}
create index age
find age > 30
get "nobody"
$ kvstore in out && cat out/results.txt
[1] ok put created
[2] ok put created
[3] ok create index age entries 2
[4] ok find 1 plan index age
  "u1" = {"age":36,"name":"ada"}
[5] error not-found
```

### Commands

| Command | Effect |
|---|---|
| `put KEY VALUE` | store a document |
| `get KEY` | print a document |
| `delete KEY` | remove a document |
| `update KEY PATH VALUE` | set a field (missing intermediate objects are created) |
| `unset KEY PATH` | remove a field |
| `scan [from K] [to K] [limit N] [reverse] [keys]` | range scan; `from` inclusive, `to` exclusive |
| `find PRED [limit N]` | documents matching a predicate, in key order |
| `create index PATH` / `drop index PATH` / `indexes` | manage secondary indexes |
| `begin` / `commit` / `rollback` | explicit transactions |
| `checkpoint` | copy the log into the main file and empty the log |
| `stat` | page, free-list, tree and log counters |

Keys are string literals of 1–128 bytes. Values are `null`, `true`, `false`,
64-bit integers, strings, lists `[1,2]` and objects `{name:"ada"}`. Paths are
dotted field names (`address.city`). Predicates combine
`path ==|!=|<|<=|>|>= value`, `exists path`, `missing path`, `not(...)`,
`and` and `or`; `find` uses a secondary index when one applies and reports its
plan (`plan scan` or `plan index PATH`).

Each command line yields a block: `[N] ok …` or `[N] error KIND`, followed by
indented payload lines. See `SPEC.md` for every status line and error kind.

## Library

An in-memory database is created with `Database::new()`; `Database::open(Some(&main), Some(&wal))`
opens existing file images and recovers from the log. The library never touches the
file system: it works on the byte images of `main.tdb` and `main.twal`.

```rust
use tessera::{parse_command, Command, Database, Path, ScanOptions, Value};

fn main() -> tessera::Result<()> {
    let mut db = Database::new();

    // Typed API.
    let Command::Put { value, .. } = parse_command(r#"put "u1" {name:"ada", age:36}"#)? else {
        unreachable!()
    };
    db.put(b"u1", &value)?;
    db.create_index(&Path::parse("age")?)?;
    db.begin()?;
    db.update(b"u1", &Path::parse("age")?, Value::Int(37))?;
    db.commit()?;
    println!("{}", db.get(b"u1")?.render()); // {"age":37,"name":"ada"}
    let rows = db.scan(&ScanOptions { keys_only: true, ..Default::default() })?;
    assert_eq!(rows.len(), 1);

    // Command language: the text returned is the content of results.txt.
    let results = db.run_script("get \"u1\"\nstat\n");
    print!("{results}");

    // The two files, ready to be written anywhere and reopened later.
    let (main, wal) = (db.main_bytes().to_vec(), db.wal_bytes().to_vec());
    let reopened = Database::open(Some(&main), Some(&wal))?;
    assert_eq!(reopened.get(b"u1")?, db.get(b"u1")?);
    Ok(())
}
```

### Layout

| Module | Responsibility |
|---|---|
| `crc` | CRC-32 |
| `value`, `path` | document values (serialise, render, compare) and field paths |
| `lexer`, `parser`, `command`, `predicate` | the command language, predicates and plan selection |
| `header`, `pager`, `wal` | header page and index directory; page cache, free list, commit, checkpoint; log records and recovery scan |
| `btree`, `overflow`, `index` | canonical pages, split/borrow/merge, cursors; overflow chains; index key encoding |
| `db`, `exec`, `render` | the engine, command execution, `results.txt` formatting |

Reads never rescan the log after recovery: pages are served from the open
transaction's dirty pages, then an in-memory map of the newest committed log
images, then the main file. Range walks are one descent plus the leaf chain
(reverse walks keep the descent path), `scan`/`find` stop at their limit, and an
index plan collects primary keys first and fetches documents in key order.

## Tests

`cargo test` runs the unit tests in each module, the doc tests, and the
integration tests in `tests/`:

- `spec_examples.rs` — the worked examples of the specification;
- `model.rs` — randomised workloads checked against a `BTreeMap` model, with
  and without indexes, transactions, checkpoints and reopening;
- `recovery.rs` — recovery from a log cut at every byte offset, and damaged logs;
- `problem_suite.rs` — the public cases in `../problems/kvstore/tests`
  (byte-for-byte on all three output files), when present.
