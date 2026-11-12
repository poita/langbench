# Tessera

Tessera is an embedded, single-file transactional document store written in D
using only the standard library. It has

* a **B+tree primary index** over canonical 1 KiB pages, with overflow pages for
  large documents (up to 64 KiB each),
* a **write-ahead log** with CRC-32 protected records, crash recovery from a log
  truncated at any byte, and checkpointing,
* **explicit and implicit transactions** (`begin` / `commit` / `rollback`),
* **secondary indexes** on (nested) document fields with a tiny query planner,
* a **small command language** (`put`, `get`, `delete`, `update`, `unset`,
  `scan`, `find`, `create index`, …).

The file format is fully deterministic: the same script run on the same input
always produces byte-identical `main.tdb` and `main.twal` files. Everything —
the CRC-32, the page format, the log format and the B+tree — is implemented from
scratch; there are no dependencies beyond Phobos.

The format and the command language are defined in
[`../problems/kvstore/SPEC.md`](../problems/kvstore/SPEC.md).

## Building

Requirements: LDC 1.41 and dub 1.40.

```sh
./build.sh                  # same as: dub build -b release --compiler=ldc2
```

This produces `bin/tessera`. To run the unit tests:

```sh
dub test --compiler=ldc2
```

## Command-line tool

```sh
./run.sh <input dir> <output dir>      # or: bin/tessera <input dir> <output dir>
```

The input directory holds

| entry          | meaning                                                         |
|----------------|-----------------------------------------------------------------|
| `commands.txt` | the script, one command per line (required)                     |
| `main.tdb`     | an existing database file (optional)                            |
| `main.twal`    | an existing write-ahead log, possibly cut short (optional)      |

The tool replays the log's committed transactions over the database, runs the
script, rolls back a transaction left open at the end of the script, and writes
three files to the output directory:

* `results.txt`: one result block per command line (`[3] ok put created`, or
  `[4] error not-found`, with payload lines indented by two spaces),
* `main.tdb`: the database file,
* `main.twal`: the write-ahead log.

The exit status is `0` unless the arguments are wrong or the input cannot be read.

### Commands

```
begin | commit | rollback | checkpoint | stat | indexes
put "key" <value>             get "key"                 delete "key"
update "key" a.b.c <value>    unset "key" a.b.c
scan [from "k"] [to "k"] [limit n] [reverse] [keys]
find <predicate> [limit n]
create index a.b              drop index a.b
```

Values are JSON-like: `null`, `true`, `false`, 64-bit integers, strings with
JSON escapes, lists `[1,2]` and objects `{name:"ada",age:36}` (field names may be
bare words). Predicates combine `path op value` (`== != < <= > >=`), `exists path`,
`missing path`, `not(...)`, `and`, `or` and parentheses.

Example script and its output:

```
put "u1" {name:"ada",age:36}          [1] ok put created
put "u2" {name:"bob",age:29}          [2] ok put created
create index age                      [3] ok create index age entries 2
find age > 30                         [4] ok find 1 plan index age
                                        "u1" = {"age":36,"name":"ada"}
```

## Using the library

The package `tessera` (module `tessera`) re-exports everything; `Engine` is the
high-level entry point.

```d
import std.stdio : writeln;
import tessera;

void main()
{
    // An empty database; pass the bytes of main.tdb / main.twal to resume one.
    auto db = new Engine;

    writeln(db.execute(`put "u1" {name:"ada",age:36}`));  // [1] ok put created
    writeln(db.execute(`get "u1"`));                      // [2] ok get value
                                                          //   {"age":36,"name":"ada"}
    db.execute("checkpoint");

    // The two files a run leaves behind:
    const(ubyte)[] mainTdb  = db.databaseImage;
    const(ubyte)[] mainTwal = db.logImage;

    // Reopen later, replaying whatever the log committed:
    auto again = new Engine(mainTdb, mainTwal);
    writeln(again.execute(`scan`));
}
```

To use the library from another dub project:

```sdl
dependency "tessera" path="../kvstore"
subConfiguration "tessera" "library"
```

## Layout

```
source/app.d               the command-line tool
source/tessera/
  package.d                public re-exports
  crc.d, bytes.d           CRC-32, big-endian and byte-string helpers
  value.d                  document values: serialise, render, compare, paths
  header.d                 header page and index directory
  node.d                   canonical B+tree pages
  btree.d                  insert, delete, split, borrow/merge, range walks
  overflow.d               documents and overflow chains
  index.d                  secondary index key encoding
  pager.d                  page cache, overlay, free list, commit/rollback
  wal.d, recover.d         log records, recovery scan, opening a database
  checkpoint.d             copying the log into the main file
  lexer.d, parser.d        command language
  query.d                  predicates and plan selection
  engine.d, render.d       command execution and result blocks
```

Unit tests live next to the code in `unittest` blocks and include the worked
examples of the specification.
