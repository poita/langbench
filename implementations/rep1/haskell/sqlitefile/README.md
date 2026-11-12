# sqlitefile

A from-scratch reader for SQLite 3 database files, written in Haskell using
only GHC's bundled libraries. It parses the file format itself — pager,
B-trees (tables and indexes), overflow chains, records, the schema's
`CREATE TABLE` / `CREATE INDEX` statements — and answers a small set of
queries. It does not use SQLite or any binding to it.

## Layout

| Module | Responsibility |
|--------|----------------|
| `SqliteFile` | Facade: `openSession`, `runQuery` |
| `SqliteFile.Pager` | Header, pages, cell payloads, overflow chains |
| `SqliteFile.BTree` | Table scan / count / rowid lookup, index point search |
| `SqliteFile.Record` | Record (row) decoding |
| `SqliteFile.Varint` | Varints and big-endian integers |
| `SqliteFile.DDL` | Tokenizer and `CREATE TABLE` / `CREATE INDEX` parser |
| `SqliteFile.Catalog` | `sqlite_schema` rows, tables, indexes, rowid aliases |
| `SqliteFile.Value` | Values, ordering, type affinity |
| `SqliteFile.Format` | `%.15g`-style real formatting |
| `SqliteFile.Query` | Command AST and parser |
| `SqliteFile.Exec` | Query execution and row rendering |

## Build

```
cabal build            # library + executable
cabal test             # hspec / QuickCheck suite
./build.sh             # same as `cabal build exe:sqlitefile`
```

Requires GHC 9.14 and cabal 3.18.

## Command line

```
sqlitefile <input dir> <output dir>        # or: ./run.sh <input dir> <output dir>
```

The input directory holds one `*.sqlite` file and `queries.txt` (one query per
line). For query *n* the tool writes `NNN.txt` into the output directory. A
query that cannot be answered produces a file containing `error`; the exit
status is 0 regardless.

Queries:

```
.tables
.schema <table>
COUNT <table>
SELECT <*|col,...> FROM <table> [WHERE col op lit [AND ...]] [ORDER BY col [ASC|DESC]] [LIMIT n]
INDEX <index> <literal>
```

with `op` one of `= != < <= > >= IS IS NOT`, and literals being numbers,
`'strings'`, `X'hex'` blobs or `NULL`. Output follows the `sqlite3` shell's
list mode (tab-separated, `NULL` for nulls, blobs in upper-case hex, reals
formatted like `%.15g` with a guaranteed `.0`).

## Library example

```haskell
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import SqliteFile

main :: IO ()
main = do
  bytes <- BS.readFile "people.sqlite"
  Right session <- openSession bytes
  Right out <- runQuery session (B.pack "SELECT name, age FROM people ORDER BY age DESC LIMIT 2")
  B.putStr out
```

`runQuery` returns `Left (QueryError _)` for malformed queries and unknown
names, and `Left (CorruptDatabase _)` if the file turns out to be damaged.

## Design notes

* The whole file is read into memory; pages are zero-copy slices.
* `SELECT` is always a full scan of the table B-tree, filtered lazily (so
  `LIMIT` without `ORDER BY` stops early); `ORDER BY` stably sorts all matches.
* `COUNT` sums leaf-page cell counts and decodes no records.
* `INDEX` binary-searches the index B-tree (interior cells carry entries too),
  then fetches each row by a rowid search of the table B-tree.
* Only the schema catalog is shared between queries; nothing else is cached.
