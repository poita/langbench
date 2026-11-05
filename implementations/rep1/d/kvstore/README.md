# kvstore — Tessera

Tessera is an embedded, single-file transactional document store written in D
(standard library only). It has a write-ahead log, a B+tree primary index,
overflow pages for large documents, secondary indexes on document fields, crash
recovery, checkpointing and a small command language. The on-disk formats are
fully specified, so two implementations produce byte-identical database and
log files for the same script.

The project has two parts:

* **`tessera`**, a library (`source/tessera/`) with a documented public API;
* **`kvstore`**, a thin command-line tool (`app/main.d`) that runs a command
  script against a database directory.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces `bin/kvstore`. `./run.sh <input dir> <output dir>` runs it from
any working directory.

Unit tests (kept in `tests/`, separate from the library source):

```sh
dub test --compiler=ldc2
```

## Command-line use

```
kvstore <input dir> <output dir>
```

The input directory holds

| File          | Meaning                                                              |
|---------------|----------------------------------------------------------------------|
| `commands.txt`| the script, one command per line (required)                          |
| `main.tdb`    | an existing database file (optional)                                 |
| `main.twal`   | an existing write-ahead log, possibly truncated or damaged (optional)|

The tool replays any committed transactions found in the log, runs the script,
rolls back a transaction still open at the end, and writes three files into the
output directory: `results.txt` (one result block per command line),
`main.tdb` and `main.twal`. The exit status is 0 unless the arguments are wrong
or a file cannot be read or written; command failures are reported in
`results.txt` as `error <kind>`.

### Command language

```
begin | commit | rollback | checkpoint | stat | indexes
put "key" <value>             get "key"            delete "key"
update "key" a.b.c <value>    unset "key" a.b.c
scan [from "k"] [to "k"] [limit n] [reverse] [keys]
find <predicate> [limit n]
create index a.b              drop index a.b
```

Values are `null`, `true`, `false`, 64-bit integers, strings with JSON escapes,
lists `[1,2]` and objects `{name:"ada","age":36}` (at most 32 levels deep).
Predicates combine comparisons (`age >= 30`, `name == "ada"`), `exists path`,
`missing path`, `not(...)`, `and` and `or`.

Example script and its `results.txt`:

```
put "u1" {name:"ada",age:36}          [1] ok put created
create index age                      [2] ok create index age entries 1
find age > 30                         [3] ok find 1 plan index age
                                        "u1" = {"age":36,"name":"ada"}
```

The full definition (formats, error precedence, page allocation order) is in
`problems/kvstore/SPEC.md` of the task this project implements.

## Library layout

| Module                | Responsibility                                                    |
|-----------------------|-------------------------------------------------------------------|
| `tessera.crc`         | table-driven CRC-32                                               |
| `tessera.bytes`       | big-endian access, byte-wise comparison, growable byte buffer     |
| `tessera.value`       | document values: serialise, compare, field paths                  |
| `tessera.render`      | canonical text rendering of values and numbers                    |
| `tessera.lexer`, `tessera.parser`, `tessera.ast` | command language front end              |
| `tessera.header`      | header page and index directory                                   |
| `tessera.wal`         | log records and recovery                                          |
| `tessera.pager`       | page layers (dirty set, log overlay, main file), free list, commit, checkpoint |
| `tessera.node`        | canonical B+tree page encode/decode and raw access                |
| `tessera.btree`       | search, cursors, insert, split, delete, borrow/merge              |
| `tessera.docstore`    | documents and overflow chains                                     |
| `tessera.indexing`    | index key encoding, maintenance, create/drop, candidate scans     |
| `tessera.query`       | predicate evaluation and plan selection                           |
| `tessera.database`    | the typed `Database` API                                          |
| `tessera.interpreter` | command lines → `results.txt` blocks                              |

`import tessera;` gives the public API.

### Using the library

```d
import std.file : write;
import std.stdio : writeln;
import tessera;

void main()
{
    // Start from a fresh database (or pass the bytes of main.tdb / main.twal).
    auto db = new Database();

    db.put("u1", Value.object(["name", "age"], [Value.string_("ada"), Value.integer(36)]));
    db.put("u2", Value.object(["name", "age"], [Value.string_("bob"), Value.integer(29)]));
    db.createIndex(["age"]);

    db.begin();
    db.update("u2", ["age"], Value.integer(41));
    db.commit();

    auto found = db.find(parseCommand(`find age > 30`).pred);
    assert(found.plan == "index age" && found.rows.length == 2);
    foreach (row; found.rows)
        writeln(row.key, " = ", renderToString(row.doc));

    try
        db.get("missing");
    catch (TesseraException e)
        assert(e.kind == ErrorKind.notFound);

    // Persist: the database file and the write-ahead log.
    write("main.tdb", db.databaseBytes);
    write("main.twal", db.logBytes);
}
```

Every failing operation throws `TesseraException` (with an `ErrorKind`) and
leaves the database unchanged. Operations outside `begin`/`commit` run in an
implicit transaction. `Interpreter` runs command-language scripts against a
`Database` and produces the text of `results.txt`.
