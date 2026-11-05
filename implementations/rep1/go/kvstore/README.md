# kvstore — Tessera, a transactional document store

Tessera is an embedded, single-file transactional document store written in Go
with only the standard library. It has:

- a **B+tree** primary index over byte-string keys, with canonical 1 KiB pages
  (the database file is byte-for-byte deterministic);
- **overflow pages** for documents larger than 192 bytes (up to 64 KiB);
- JSON-like documents (null, bool, int64, string, list, object);
- **secondary indexes** on field paths (`address.city`), used by `find`;
- a **write-ahead log** with CRC-32-protected records, explicit and implicit
  transactions, crash recovery from a truncated or damaged log, and
  checkpointing (automatic at 256 KiB of log);
- a small **command language** (`put`, `get`, `scan`, `find`, …).

The CRC-32, the file and log formats and the B+tree are all implemented here;
nothing from the standard library is used for them. The storage engine works
on in-memory byte images of the database file and the log, so it is easy to
embed and to test.

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # builds bin/kvstore
go test ./...       # runs the unit tests
```

`build.sh` is equivalent to `go build -o bin/kvstore ./cmd/kvstore`, and works
from any directory.

## Command-line tool

```
run.sh <input dir> <output dir>        # or: bin/kvstore <input dir> <output dir>
```

The input directory contains

| File          | Required | Meaning                                           |
|---------------|----------|---------------------------------------------------|
| `commands.txt`| yes      | one command per line (LF separated)               |
| `main.tdb`    | no       | an existing database file                         |
| `main.twal`   | no       | an existing write-ahead log (may be truncated)    |

and the program writes `results.txt` (one result block per command),
`main.tdb` and `main.twal` into the output directory. Without `main.tdb` it
starts from a fresh database; a present `main.twal` is recovered first (only
committed transactions are applied, anything after the last intact commit
record is discarded). A transaction still open when the script ends is rolled
back. The exit status is 0 unless the files cannot be read or written —
command errors are reported in `results.txt`, never in the exit status.

### Commands

```
begin | commit | rollback | checkpoint | stat | indexes
put    "key" <value>
get    "key"
delete "key"
update "key" <path> <value>      set a field (creating objects on the way)
unset  "key" <path>              remove a field
scan   [from "k"] [to "k"] [limit n] [reverse] [keys]
find   <predicate> [limit n]
create index <path>
drop   index <path>
```

Values are JSON-like literals: `null`, `true`, `false`, integers, strings with
JSON escapes, lists `[1,2]` and objects `{name:"ada", "age":36}` (field names
may be bare words). Paths are dotted field names such as `address.city`.
Predicates combine comparisons (`age >= 30`, `name == "ada"`), `exists p`,
`missing p`, `not(...)`, `and`, `or` and parentheses.

Example `commands.txt`:

```
put "b" 2
put "a" {name:"ada",age:36}
create index age
find age >= 30 limit 5
get "a"
```

and the resulting `results.txt`:

```
[1] ok put created
[2] ok put created
[3] ok create index age entries 1
[4] ok find 1 plan index age
  "a" = {"age":36,"name":"ada"}
[5] ok get value
  {"age":36,"name":"ada"}
```

Failed commands produce `[k] error <kind>` (for example `not-found`,
`syntax`, `doc-too-large`) and change nothing.

## Library

The module path is `example.com/kvstore`. The code is split by responsibility:

| Package | Responsibility |
|---------|----------------|
| `kvstore` (root) | facade: `Open`, `Store.Exec`, `RunScript`; result-block formatting |
| `engine` | pager and page overlay, header and index directory, B+tree, overflow chains, index keys, WAL, transactions, recovery, checkpoint, query plans |
| `lang` | lexer and recursive-descent parser of the command language |
| `query` | predicate tree and its evaluation |
| `value` | document model: serialisation, rendering, comparison, field paths |
| `crc` | CRC-32 |
| `kverr` | the error kinds |
| `cmd/kvstore` | the command-line tool |

### Example

```go
package main

import (
	"fmt"

	"example.com/kvstore"
	"example.com/kvstore/engine"
	"example.com/kvstore/value"
)

func main() {
	// Command-language facade: each call returns one result block.
	s := kvstore.Open(nil, nil) // fresh database, empty log
	fmt.Print(s.Exec(`put "ada" {name:"Ada", age:36}`))
	fmt.Print(s.Exec(`create index age`))
	fmt.Print(s.Exec(`find age > 30`))

	// The files as they would be written to disk.
	dbFile, walFile := s.Files()

	// Reopen from those images (recovery replays the log).
	s = kvstore.Open(dbFile, walFile)
	fmt.Print(s.Exec(`get "ada"`))

	// The engine API can be used directly, without the command language.
	db := engine.Open(nil, nil)
	doc := value.NewObject([]value.Field{{Name: "n", Value: value.NewInt(1)}})
	db.Put([]byte("k"), doc)
	got, _ := db.Get([]byte("k"))
	fmt.Println(value.Render(got)) // {"n":1}
}
```

`Store.Exec` never fails: errors become `error <kind>` result blocks.
`engine.DB` methods return `*kverr.Error` values (use `kverr.KindOf`).
Writes made outside an explicit `Begin`/`Commit` are committed immediately.

## Layout

```
build.sh, run.sh      build and run scripts
cmd/kvstore/          command-line tool
kvstore.go            facade
engine/               storage engine
lang/ query/ value/   language, predicates, documents
crc/ kverr/           checksum, error kinds
```
