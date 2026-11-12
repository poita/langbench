# Tessera

Tessera is an embedded, single-file transactional document store written in
C++20 with no dependencies beyond the standard library. It provides:

- a **B+tree primary index** over byte-string keys, with documents of up to
  64 KiB (large values spill into overflow pages);
- **secondary indexes** on document field paths (up to 16);
- a **write-ahead log** with atomic multi-page commits, explicit and implicit
  transactions, checkpointing and crash recovery;
- a small **command language** (`put`, `get`, `scan`, `find`, `create index`, ...).

Every byte of the database file and the log is fully determined by the sequence
of operations (canonical pages, fixed split and rebalance rules, fixed page
allocation order), so two runs of the same script produce identical files.
CRC-32, the file formats and the B+tree are implemented from scratch.

## Layout

| Path | Contents |
|---|---|
| `include/tessera/`, `src/` | the library, one module per header/source pair |
| `tools/main.cpp` | `tessera-cli`, the command-line tool |
| `tests/` | GoogleTest unit and model-based tests |
| `build.sh`, `run.sh` | build and run helpers |

Library modules:

| Module | Responsibility |
|---|---|
| `crc32` | table-driven CRC-32 |
| `value` | document values: serialise, deserialise, render, compare, field paths |
| `header`, `pager` | page 1 and the index directory; page cache, WAL overlay, dirty set, free list |
| `node`, `btree` | canonical B+tree pages; search, insert, split, delete, borrow, merge, scans |
| `overflow` | overflow page chains |
| `index_key` | order-preserving index key encoding |
| `wal` | log records, append, recovery scan |
| `query` | predicates, evaluation and plan selection |
| `database` | the public engine: transactions, documents, indexes, queries, checkpoint, recovery |
| `lexer`, `parser`, `command` | the command language |
| `executor`, `render` | run command lines, format `results.txt` blocks |

## Building

Requires a C++20 compiler and CMake 3.20+. GoogleTest is needed for the tests
(`-DTESSERA_BUILD_TESTS=OFF` skips them).

```sh
./build.sh                       # Release build into ./build
./build/tessera-tests            # run the unit tests (or: ctest --test-dir build)
```

or by hand:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

## Command-line tool

```sh
./run.sh <input dir> <output dir>
```

The input directory holds `commands.txt` (one command per line) and optionally
an existing database `main.tdb` and log `main.twal`. The tool runs the script and
writes exactly three files into the output directory:

- `results.txt` — one result block per command line (`[3] ok get value` followed
  by indented payload lines, or `[3] error not-found`);
- `main.tdb` — the database file after the run;
- `main.twal` — the write-ahead log after the run.

Standard input is not read. The exit status is 0 on success; command errors are
reported in `results.txt`, not through the exit status. A transaction still open
when the script ends is rolled back. A log cut off mid-write is recovered: only
transactions whose commit record is intact are applied, and the rest is trimmed.

### Commands

```
begin | commit | rollback | checkpoint | stat | indexes
put "key" <value>          get "key"             delete "key"
update "key" a.b.c <value> unset "key" a.b.c
scan [from "k"] [to "k"] [limit n] [reverse] [keys]
find <predicate> [limit n]
create index a.b           drop index a.b
```

Values are `null`, `true`, `false`, 64-bit integers, strings, lists
`[1,"x"]` and objects `{name:"ada",age:36}`. Predicates combine comparisons
(`age >= 30`, `name == "ada"`), `exists path`, `missing path`, `not(...)`,
`and`, `or` and parentheses. For example:

```
put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
create index age
find age >= 30
```

produces

```
[1] ok put created
[2] ok put created
[3] ok create index age entries 2
[4] ok find 1 plan index age
  "u1" = {"age":36,"name":"ada"}
```

## Using the library

```cpp
#include <tessera/tessera.hpp>
#include <iostream>

int main() {
  using namespace tessera;

  Database db;  // a fresh in-memory-image database; see DatabaseImage to load files
  db.put("u1", parse_value_literal("{name:\"ada\",age:36}"));
  db.put("u2", Value::object({{"name", Value::string("bob")}, {"age", Value::integer(29)}}));
  db.create_index({"age"});

  db.begin();                                   // explicit transaction
  db.update("u2", {"age"}, Value::integer(30));
  db.commit();                                  // appends to the write-ahead log

  auto cmd = parse_command("find age >= 30");
  for (const Entry& e : db.find(*cmd.predicate, std::nullopt).entries)
    std::cout << e.key << " = " << render(*e.doc) << "\n";

  try {
    db.erase("missing");
  } catch (const Error& e) {
    std::cout << "error " << error_name(e.kind()) << "\n";   // error not-found
  }

  // The state as it would be written to disk:
  const std::vector<std::uint8_t>& main_file = db.main_file();   // main.tdb
  const std::vector<std::uint8_t>& log = db.wal_file();          // main.twal
  Database reopened(DatabaseImage{main_file, log});              // recovers from them
}
```

`Database` throws `tessera::Error` (with an `ErrorKind`) when an operation fails;
a failing operation changes nothing. `Database` keeps the main file and log as
byte vectors; `tools/main.cpp` shows how to load and save them. `run_script`
(`executor.hpp`) runs command-language text against a `Database` and returns the
`results.txt` text.

## Format summary

Pages are 1024 bytes; page 1 is the header with the index directory. B+tree
pages use a canonical encoding (cell pointer array in key order, cells packed
against the end of the page), so a page's bytes are a pure function of its
cells. Committed changes live in the log until a checkpoint (explicit, or
automatic when the log reaches 262144 bytes) copies them into the main file.
