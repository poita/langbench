# Tessera

Tessera is an embedded, single-file transactional document store written in Go
with no dependencies beyond the standard library. It provides

- a B+tree primary index over canonical 1024-byte pages, with overflow pages
  for documents larger than 192 bytes,
- secondary indexes on document field paths (up to 16),
- transactions backed by a write-ahead log, crash recovery, and checkpointing,
- a small line-oriented command language, and
- a **byte-for-byte deterministic file format**: the same script always leaves
  the same `main.tdb` and `main.twal`.

The file format, the command language and the result format are specified in
`problems/kvstore/SPEC.md` of the surrounding repository. CRC-32, the page
formats and the B+tree are implemented from scratch in this project.

## Layout

| Path | Contents |
|---|---|
| `crc/` | CRC-32 (reflected, polynomial `0xEDB88320`), table driven |
| `value/` | the document value model: serialisation, rendering, comparison, field paths, index key encoding |
| `*.go` (package `tessera`) | the engine: `db.go` (pager overlay, WAL, transactions, recovery, checkpoint), `header.go`, `node.go` (canonical pages), `btree.go` (search, insert, split, delete, borrow/merge, cursors), `overflow.go`, `index.go`, `query.go` (predicates, plan selection), `lexer.go` / `parser.go`, `api.go` (typed operations), `exec.go` (command execution and `results.txt` rendering) |
| `cmd/tessera/` | the command-line tool |

## Build

Requires Go 1.27 or newer.

```
./build.sh          # builds bin/tessera
go test ./...       # runs the unit tests
```

`build.sh` is just `go build -o bin/tessera ./cmd/tessera` and works from any
directory.

## Command-line usage

```
tessera <input dir> <output dir>      # or: ./run.sh <input dir> <output dir>
```

The input directory contains `commands.txt` (one command per line) and,
optionally, an existing `main.tdb` and `main.twal` (which may be truncated at
any byte: committed transactions are recovered, the rest is dropped). The
program writes exactly three files into the output directory:

| File | Content |
|---|---|
| `results.txt` | one result block per command line |
| `main.tdb` | the database file after the script |
| `main.twal` | the write-ahead log after the script |

A transaction still open at the end of the script is rolled back. No
checkpoint happens unless the script asks for one or the log reaches 256 KiB.
The exit status is 0 whenever the files were written; command failures are
reported in `results.txt`, never through the exit status.

### Commands

```
begin | commit | rollback | checkpoint | stat | indexes
put "key" <value>          get "key"            delete "key"
update "key" a.b <value>   unset "key" a.b
scan [from "k"] [to "k"] [limit n] [reverse] [keys]
find <predicate> [limit n]
create index a.b           drop index a.b
```

Values are JSON-like literals: `null`, `true`, `false`, 64-bit integers,
strings with JSON escapes, lists `[1,2]` and objects `{name:"ada",age:36}`
(field names may be bare words). Predicates combine `path == value` (also
`!= < <= > >=`), `exists path`, `missing path`, `not(...)`, `and`, `or` and
parentheses.

Example `commands.txt`:

```
put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
create index age
find age >= 30
scan reverse keys
```

and the resulting `results.txt`:

```
[1] ok put created
[2] ok put created
[3] ok create index age entries 2
[4] ok find 1 plan index age
  "u1" = {"age":36,"name":"ada"}
[5] ok scan 2
  "u2"
  "u1"
```

Failed commands print `error <kind>` (for example `error not-found`,
`error syntax`, `error doc-too-large`) and change nothing.

## Using the library

```go
package main

import (
	"fmt"

	"example.com/tessera"
	"example.com/tessera/value"
)

func main() {
	db := tessera.Open(nil, nil) // fresh database; or Open(mainTDB, mainTWAL)

	doc := value.ObjectValue(
		value.Field{Name: "name", Val: value.StringValue("ada")},
		value.Field{Name: "age", Val: value.IntValue(36)},
	)
	db.Put([]byte("u1"), doc)       // implicit transaction, committed at once
	db.CreateIndex("age")

	entries, plan := db.Find(tessera.Cmp([]string{"age"}, tessera.OpGe, value.IntValue(30)), -1)
	fmt.Println(plan) // index age
	for _, e := range entries {
		fmt.Printf("%s = %s\n", e.Key, value.Render(e.Doc))
	}

	db.Begin()                       // explicit transaction
	db.Update([]byte("u1"), []string{"address", "city"}, value.StringValue("Perth"))
	db.Rollback()                    // nothing was written to the log

	db.Checkpoint()                  // copy the log into the main file
	mainFile, logFile := db.DatabaseFile(), db.LogFile()
	_ = tessera.Open(mainFile, logFile) // reopen later

	// The command language is available too:
	fmt.Println(db.Exec(`get "u1"`).Status)
}
```

Errors are `*tessera.Error` values; `tessera.KindOf(err)` returns the kind
(`tessera.ErrNotFound`, `tessera.ErrDocTooLarge`, ...). A failing operation
never modifies the database. A `*tessera.DB` is not safe for concurrent use.

`tessera.RunScript(mainFile, logFile, script)` runs a whole `commands.txt`
and returns the three output files; it is what the command-line tool calls.

## Design notes

- All state is in memory: `Open` takes the bytes of the two files, and the
  tool writes them back out at the end of the run.
- A page is read from the open transaction's dirty pages, then from the log
  overlay (a map from page number to its newest committed image, built in one
  forward pass over the log when the database is opened), then from the main
  file. Reads never rescan the log.
- Pages are immutable byte slices; every modification re-encodes the page
  canonically, which is what makes the files byte-reproducible.
- `scan` and `find` stop at their `limit`; `find` with an index plan collects
  the candidate primary keys from the index range, sorts them, and then
  fetches documents in key order.
- Reverse scans keep the descent path and step to the previous leaf through it
  (leaves only have forward links).
