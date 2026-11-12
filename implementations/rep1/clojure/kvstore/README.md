# kvstore — Tessera

An embedded, single-file transactional document store written in Clojure: a
write-ahead log, a B+tree primary index over canonical 1024-byte pages,
overflow pages for large documents, secondary indexes on document fields,
crash recovery, checkpointing and a small command language.

The on-disk formats are fully specified (`problems/kvstore/SPEC.md` in the
repository this project lives in), down to the byte: two correct
implementations produce identical `main.tdb` and `main.twal` files. CRC-32,
the file and log formats and the B+tree are all implemented here from scratch;
the only dependency is Clojure itself (plus `test.check` and the Cognitect
test runner for the tests).

## Layout

| Namespace              | Responsibility                                                    |
|------------------------|-------------------------------------------------------------------|
| `kvstore.core`         | **Public API**: open, put/get/delete, scan, find, indexes, transactions |
| `kvstore.cli`          | Command-line tool (`<input dir> <output dir>`)                    |
| `kvstore.exec`         | Runs one command-language line and formats its result block       |
| `kvstore.parser`, `kvstore.lexer` | The command language: tokens, values, paths, predicates |
| `kvstore.query`        | Predicate evaluation and `find` plan selection                    |
| `kvstore.docs`         | Documents on the primary tree, with index maintenance             |
| `kvstore.index`        | Index key encoding, build, drop, candidate scans                  |
| `kvstore.btree`        | Canonical page codec, search, split, borrow/merge, range walks    |
| `kvstore.overflow`     | Overflow page chains                                              |
| `kvstore.freelist`, `kvstore.header` | Page allocation; header page and index directory    |
| `kvstore.pager`        | Page cache: dirty set, log overlay, main file                     |
| `kvstore.txn`          | Begin / commit / rollback and implicit transactions               |
| `kvstore.wal`, `kvstore.recover`, `kvstore.checkpoint` | Log records, recovery, checkpointing |
| `kvstore.value`        | Document values: serialisation, rendering, paths                  |
| `kvstore.crc`, `kvstore.bytes`, `kvstore.limits` | CRC-32, byte helpers, constants        |

## Building

Requires Java and the Clojure CLI (`clojure`).

```sh
./build.sh      # AOT-compiles kvstore.cli into classes/ and records the classpath
```

## Command-line use

```sh
./run.sh <input dir> <output dir>
```

The input directory holds `commands.txt` (one command per line) and,
optionally, an existing `main.tdb` and `main.twal`. The tool runs the script
and writes exactly three files into the output directory:

* `results.txt` — one result block per command line;
* `main.tdb` — the database file;
* `main.twal` — the write-ahead log.

The exit status is 0 whenever the script could be run, even if individual
commands failed (they report `error <kind>` in `results.txt`).

```
$ cat in/commands.txt
put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
create index age
find age > 30
$ ./run.sh in out && cat out/results.txt
[1] ok put created
[2] ok put created
[3] ok create index age entries 2
[4] ok find 1 plan index age
  "u1" = {"age":36,"name":"ada"}
```

Commands: `begin`, `commit`, `rollback`, `checkpoint`, `stat`, `indexes`,
`put KEY VALUE`, `get KEY`, `delete KEY`, `update KEY PATH VALUE`,
`unset KEY PATH`, `scan [from K] [to K] [limit N] [reverse] [keys]`,
`find PREDICATE [limit N]`, `create index PATH`, `drop index PATH`.
Values are JSON-like literals (`null`, `true`, `false`, integers, strings,
lists, objects with bare or quoted field names).

## Library use

```clojure
(require '[kvstore.core :as kv])

(def db (kv/open))                       ; fresh, in-memory
(kv/put! db "u1" {"name" "ada" "age" 36})
(kv/put! db "u2" {"name" "bob" "age" 29})

(kv/get db "u1")                         ;=> {"name" "ada", "age" 36}
(kv/create-index! db "age")              ;=> 2
(kv/find db "age > 30")                  ;=> {:plan "index age", :rows [["u1" {...}]]}
(kv/scan db {:from "u1" :reverse? true :keys? true})

(kv/begin! db)
(kv/update! db "u1" "address.city" "oslo")
(kv/rollback! db)                        ; the update never happened

(kv/checkpoint! db)                      ; copy the log into the main file
(let [{:keys [main wal]} (kv/files db)]  ; the bytes of main.tdb / main.twal
  (kv/open {:main main :wal wal}))       ; reopen (with crash recovery)
```

Documents are plain Clojure data (`nil`, booleans, longs, strings, vectors,
maps with string keys). Failures are `ex-info` exceptions whose `ex-data` has
a `:kind` such as `:not-found`, `:bad-key`, `:doc-too-large` or `:txn-active`.
`(kv/execute! db "put \"a\" 1")` runs a line of the command language.

## Tests

```sh
clojure -M:test
```

The suite covers the CRC vectors, value serialisation, the lexer and parser
(including the error-precedence rules), every worked example of the spec,
crash recovery on truncated and damaged logs, the public API, and
`test.check` properties that replay random workloads against a sorted-map
model (checking contents, index results, page accounting and reopen
round-trips). The problem's own test-suite is run with
`python3 run_tests.py kvstore -- kvstore/run.sh`.
