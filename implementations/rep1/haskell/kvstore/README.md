# kvstore — Tessera, a transactional document store

Tessera is an embedded, single-file document store written in Haskell, using
only GHC's bundled libraries. It has:

- a page-based **B+tree** primary index with canonical (byte-deterministic) pages,
- **overflow pages** for documents larger than 192 bytes (up to 64 KiB),
- **secondary indexes** on document field paths (up to 16),
- a **write-ahead log** with CRC-32-checked records, crash recovery and checkpointing,
- explicit and implicit **transactions**,
- a small **command language** (`put`, `get`, `scan`, `find`, `create index`, …).

Everything is deterministic: two runs over the same input produce byte-identical
database and log files. The on-disk format, the command language and the result
format are specified in `problems/kvstore/SPEC.md` of the parent workspace.

## Layout

| Path | Contents |
|---|---|
| `src/Tessera/*.hs` | the library (see below) |
| `app/Main.hs` | the command-line tool |
| `test/` | the test suite (hspec and QuickCheck) |
| `build.sh`, `run.sh` | build the tool to `bin/kvstore`; run it |

Library modules, by responsibility:

| Module | Responsibility |
|---|---|
| `Tessera` | umbrella module: the types you need |
| `Tessera.Store` | **the public API**: put, get, delete, update, scan, find, indexes, transactions |
| `Tessera.Value`, `Tessera.Path`, `Tessera.IndexKey` | value model, serialisation, rendering; field paths; index key encoding |
| `Tessera.Lexer`, `Tessera.Parser`, `Tessera.Command` | the command language |
| `Tessera.Query` | predicates, scan options, plan selection |
| `Tessera.Exec`, `Tessera.Render`, `Tessera.Script` | running commands and formatting `results.txt` |
| `Tessera.Page`, `Tessera.BTree`, `Tessera.Overflow`, `Tessera.Index` | canonical pages, the B+tree, overflow chains, index maintenance |
| `Tessera.Pager`, `Tessera.WAL`, `Tessera.CRC` | page cache and transactions, log format and recovery, checksum |

The store never touches the file system itself: the database file and the log
go in and come out as `ByteString`s, which keeps the engine easy to test.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the binary to bin/kvstore
cabal test          # run the test suite
```

## The command-line tool

```sh
./run.sh <input dir> <output dir>
```

`<input dir>` holds `commands.txt` (one command per line) and optionally
`main.tdb` (an existing database) and `main.twal` (an existing log, possibly
truncated). The tool replays the log, runs the commands, and writes exactly
three files into `<output dir>`: `results.txt` (one result block per command),
`main.tdb` and `main.twal`. The exit status is 0 on success; command failures
are reported in `results.txt` as `error <kind>`.

```
$ cat in/commands.txt
put "b" 2
put "a" {name:"ada",age:36}
get "a"
scan
$ ./run.sh in out && cat out/results.txt
[1] ok put created
[2] ok put created
[3] ok get value
  {"age":36,"name":"ada"}
[4] ok scan 2
  "a" = {"age":36,"name":"ada"}
  "b" = 2
```

Commands: `begin`, `commit`, `rollback`, `checkpoint`, `stat`, `indexes`,
`put KEY VALUE`, `get KEY`, `delete KEY`, `update KEY PATH VALUE`,
`unset KEY PATH`, `scan [from K] [to K] [limit N] [reverse] [keys]`,
`find PREDICATE [limit N]`, `create index PATH`, `drop index PATH`.
Values are JSON-like literals (`null`, `true`, integers, strings, lists, objects
with bare or quoted field names).

## Using the library

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Tessera
import qualified Tessera.Store as Store
import Tessera.Query (defaultScanOptions)

main :: IO ()
main = do
  db <- Store.newStore                                  -- or Store.openStore (Just tdb) (Just twal)
  let Right ada = parseValue "{name:\"ada\",age:36}"
      Right age = parsePath "age"
  _ <- Store.put db "u1" ada                            -- Right Created
  _ <- Store.createIndex db age                         -- Right 1
  Store.get db "u1" >>= print                           -- Right (VObject ...)
  Store.scan db defaultScanOptions >>= print            -- all documents, ascending
  Store.begin db >> Store.put db "u2" VNull >> Store.rollback db

  -- the two files, as they would be written to disk
  tdb  <- Store.storeFileBytes db
  twal <- Store.storeLogBytes db
  print (length (show tdb), length (show twal))
```

Operations return `Either ErrorKind a`. A failing operation changes nothing.
Outside `begin`/`commit`, each write is its own committed transaction.
To run command text instead, use `Tessera.Script.runScript`:

```haskell
r <- runScript Nothing Nothing "put \"a\" 1\nget \"a\"\n"
-- resultsText r == "[1] ok put created\n[2] ok get value\n  1\n"
```

## Notes on the implementation

- Pages are re-encoded from their logical content on every change, so the
  files are byte-for-byte reproducible.
- Reads go through a log *overlay* (a map from page number to newest committed
  image) built once at open time; the log is never rescanned.
- `find` plans are deterministic and reported (`plan scan` or `plan index PATH`);
  an index plan collects candidate keys from one index range, sorts them, and
  fetches documents in primary-key order. Both plans stop at the `limit`.
- Range walks are one descent followed by the leaf chain (reverse walks prune
  with the separators). `scan` and `find` read only the documents they evaluate
  or emit, and none for `keys` or `limit 0`.
