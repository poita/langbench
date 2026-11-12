# Tessera

Tessera is an embedded, single-file transactional document store written in pure
Python (standard library only). It has

* a **write-ahead log** with crash recovery and checkpointing,
* a **B+tree** primary index over 1 KiB canonical pages,
* **overflow pages** for documents up to 64 KiB,
* **secondary indexes** on (nested) document fields,
* explicit and implicit **transactions**, and
* a small **command language** driven by the command-line tool.

The file formats are fully specified down to the byte: two correct
implementations produce byte-identical `main.tdb` and `main.twal` files, so the
library reproduces page numbers, split points, free-list order and padding
exactly (see `problems/kvstore/SPEC.md` in the repository this project came
from).

## Layout

```
pyproject.toml        project manifest (setuptools; Python >= 3.14)
build.sh, run.sh      build step and command-line launcher
src/tessera/
    database.py       Database: documents, indexes, transactions, find/scan
    cli.py            the command-line tool (thin wrapper over script.py)
    script.py         runs command scripts and formats results.txt
    parser.py lexer.py   command language: tokens, commands, literals, predicates
    query.py          predicates, evaluation, find plan selection
    btree.py          B+tree search / insert / split / delete / rebalance / scans
    pages.py          canonical B+tree page encode/decode
    pager.py          page overlay (dirty pages, log images, main file), free list, commit
    wal.py            log records, recovery scan, size accounting
    checkpoint.py     copying the log into the main file
    overflow.py       overflow chains
    header.py         header page and index directory
    indexkey.py       order-preserving index key encoding
    value.py          document value model: serialise, render, compare, paths
    crc.py            CRC-32 (hand-written, table driven)
tests/                pytest suite
```

## Build

There is nothing to compile; `build.sh` byte-compiles the package:

```sh
./build.sh
```

To install it as a package instead: `pip install .` (this provides a `tessera`
command and the `tessera` import).

## Command-line tool

```sh
./run.sh <input dir> <output dir>
# or, without run.sh:  PYTHONPATH=src python3 -m tessera <input dir> <output dir>
```

The input directory holds `commands.txt` (one command per line) and optionally
`main.tdb` (an existing database) and `main.twal` (an existing log, possibly cut
short by a crash; committed transactions in it are recovered and the rest is
dropped). The tool writes exactly three files into the output directory:

| File          | Content                                                    |
|---------------|------------------------------------------------------------|
| `results.txt` | one result block per command line                          |
| `main.tdb`    | the database file after the script ran                     |
| `main.twal`   | the write-ahead log after the script ran                   |

A transaction still open when the script ends is rolled back. The exit status
is `0` whatever individual commands did: a failing command produces an
`error <kind>` block and changes nothing.

### Commands

```
begin | commit | rollback | checkpoint | stat | indexes
put "key" <value>                   get "key"              delete "key"
update "key" a.b.c <value>          unset "key" a.b.c
scan [from "k"] [to "k"] [limit n] [reverse] [keys]
find <predicate> [limit n]
create index a.b                    drop index a.b
```

Values are JSON-like literals (`null`, `true`, `false`, 64-bit integers,
strings, lists, and objects whose field names may be bare words):
`{name: "ada", tags: ["x", 1], ok: true}`. Predicates combine
`path == != < <= > >= value`, `exists path`, `missing path`, `not(...)`, `and` and
`or`.

Example script and its `results.txt`:

```
put "u1" {name:"ada",age:36}          [1] ok put created
put "u2" {name:"bob",age:29}          [2] ok put created
create index age                      [3] ok create index age entries 2
find age >= 30                        [4] ok find 1 plan index age
                                        "u1" = {"age":36,"name":"ada"}
```

## Library

```python
from tessera import Database, TesseraError

db = Database.open()                          # fresh, in memory
# db = Database.open(open("main.tdb", "rb").read(), open("main.twal", "rb").read())

db.put("u1", {"name": "ada", "age": 36})      # True: the key was new
db.put("u2", {"name": "bob", "age": 29})
db.create_index("age")                        # -> 2 entries

result = db.find('age >= 30 and name == "ada"')
print(result.plan, result.rows)               # index age [(b'u1', {'age': 36, 'name': 'ada'})]

db.begin()                                    # explicit transaction
db.update("u2", "address.city", "oslo")
db.rollback()                                 # ... undone

try:
    db.get("nobody")
except TesseraError as e:
    print(e.kind)                             # not-found

print(db.scan(start="u1", limit=1))           # [(b'u1', {...})]
print(db.stat())                              # pages, free list, wal size, ...

db.save("main.tdb", "main.twal")              # the byte-exact files
```

Documents are plain Python values (`None`, `bool`, `int`, `str`, `list`,
`dict`). Keys may be `str` or `bytes` (1–128 bytes) and are returned as
`bytes`. Every failure raises `TesseraError` with a `kind` from the spec
(`not-found`, `doc-too-large`, `index-key-too-long`, ...) and leaves the database
unchanged. Writes outside `begin()` run in their own implicit transaction. The
log is checkpointed automatically once it reaches 256 KiB, or on demand with
`db.checkpoint()`.

`Database` methods: `open`, `open_files`, `db_image`, `wal_image`, `save`,
`begin`, `commit`, `rollback`, `checkpoint`, `put`, `get`, `update`, `unset`,
`delete`, `scan`, `find`, `plan`, `create_index`, `drop_index`, `indexes`, `stat`.
Further building blocks (`parse_command`, `parse_predicate`, `parse_value`,
`run_script`, `render`, `crc32`) are exported from the `tessera` package.

## Tests

```sh
python3 -m pytest        # configured in pyproject.toml (src/ is on the path)
```

The suite covers the CRC vectors, value serialisation and rendering, lexer and
parser error precedence, the worked examples of the specification, randomised
model-checking of the B+tree, free list, overflow chains and indexes against a
`dict` (with a full structural invariant check of every page), and recovery from
a log cut at every byte offset.
