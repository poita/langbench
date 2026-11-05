# kvstore — Tessera, a transactional document store

Build **Tessera**: an embedded, single-file transactional document store with a
write-ahead log, a B+tree primary index, overflow pages for large values,
secondary indexes on document fields, crash recovery, checkpointing, and a
small command language.

Everything in this document is invented for this problem. The file format, the
log format, the index key encoding, the command language and the result format
are *not* those of SQLite, LMDB, BoltDB, RocksDB or any other engine; where
something looks familiar, this document's definition is the one that counts.

The program is graded on two things at once:

1. the text it writes to `results.txt`, and
2. the **exact bytes** of the database file and the write-ahead log it leaves
   behind.

The second requirement is the hard one. Every byte of the format is pinned down
here: page size, page allocation order, split points, rebalancing choices,
free-list order, padding, zero filling, the order in which pages are written to
the log. Two correct implementations produce byte-identical files. If this
document appears to leave a byte undecided, re-read §11 (*Canonical pages*) and
§20 (*Determinism checklist*) — one of them decides it.

Write the CRC-32, the file and log formats and the B+tree yourself: don't use a
routine from a library, the standard library or the language for any of them.
Standard-library file I/O, containers and sorting are fine.

---

## 1. Expected size and shape

A complete implementation is roughly **8,000–12,000 lines** in a systems
language; the reference implementation, written in
Python, comes to about 2,400. A natural
decomposition, with rough line counts for a compiled language:

| Module | Lines | What it does |
|---|---|---|
| `crc` | 60 | CRC-32 (§3), table-driven. |
| `value` | 600 | The document value model (§4): parse from a literal, serialise to bytes, deserialise, deep compare, canonical one-line rendering, path get/set/unset. |
| `pager` | 700 | Page cache, the overlay of WAL images over the main file (§13), dirty-page tracking, allocation and the free list (§10). |
| `header` | 250 | The header page and the index directory (§7, §8). |
| `btree` | 2200 | Canonical page encode/decode (§11), search, insert, replace, delete, split (§12.3), borrow and merge (§12.5), scans, whole-tree traversal. |
| `overflow` | 250 | Overflow chains: write, read, free (§9). |
| `index` | 700 | Index key encoding (§14.1), index maintenance on write (§14.3), index build and drop (§14.4, §14.5), candidate range scans (§17.3). |
| `wal` | 600 | Record encoding, append, size accounting, truncation, scan and validate (§15). |
| `txn` | 400 | begin / commit / rollback, implicit transactions, checkpoint triggers (§13). |
| `recover` | 350 | Opening a database, replaying committed transactions, trimming the log (§16). |
| `checkpoint` | 250 | Copying WAL images into the main file and resetting the log (§15.6). |
| `lexer` | 350 | The token stream of the command language (§6.1). |
| `parser` | 900 | Commands, value literals, field paths, predicates (§6, §17). |
| `exec` | 900 | One function per command, the error ordering of §18. |
| `query` | 700 | Predicate evaluation, plan selection, candidate filtering (§17). |
| `render` | 400 | `results.txt` block formatting (§19). |
| `main` | 150 | Argument handling, reading the input directory, writing the output directory (§2). |

Build it in this order: value model → canonical pages → B+tree insert and
search → the pager and the WAL → transactions → delete and rebalancing →
overflow → indexes → the query language → recovery and checkpointing.

---

## 2. I/O contract

This is a **directory-mode** problem (see `CONVENTIONS.md`). The program is run
as

```
<program> <input path> <output dir>
```

with the current directory set to `problems/kvstore/`. Nothing is read from
standard input. Nothing outside `<output dir>` may be written. Anything printed
on stdout or stderr is ignored. The exit status must be `0`.

### 2.1 The input directory

`<input path>` is a directory holding one, two or three entries:

| Entry | Presence | Meaning |
|---|---|---|
| `commands.txt` | always | The command script, UTF-8, LF line endings. |
| `main.tdb` | optional | An existing database file. |
| `main.twal` | optional | An existing write-ahead log, possibly truncated at an arbitrary byte offset. |

No other entries appear and none must be read.

`commands.txt` contains one command per line. Lines are separated by LF
(`0x0A`); the final line may or may not end with one. There are no CR bytes.
There are no comments. A line may be empty or contain only spaces and tabs — it
is still a command, and it fails with `error syntax`. There are at most
`1 000 000` lines.

Precisely: the command lines are the pieces the file splits into at each LF. A
trailing LF **terminates** the last line and does not begin another, so
`a\nb\n` and `a\nb` are both two lines, while `a\nb\n\n` is three (the third
being empty, hence `error syntax`). A zero-byte `commands.txt` has **no** lines
at all, and `results.txt` is then an empty, zero-byte file.

`main.tdb`, when present, is always a **valid** Tessera database file as defined
in §7–§11: its length is a positive multiple of 1024, its first page carries the
correct magic and version, and `page_count` equals its length divided by 1024.
An implementation may assume this and need not diagnose a malformed database.

`main.twal`, when present, is an arbitrary byte string. It may be empty, a
correct log, a correct log truncated anywhere (including in the middle of a
record header, in the middle of a page payload, and immediately before or after
a commit record), or a log whose header is damaged. §16 says exactly what
happens for every one of those cases.

If `main.twal` is present but `main.tdb` is not, the log is replayed on top of a
freshly initialised database (§7.3).

### 2.2 The output directory

The program writes **exactly three files** into `<output dir>` and nothing else:

| File | Content |
|---|---|
| `results.txt` | One result block per command line, in order, UTF-8, LF line endings (§19). |
| `main.tdb` | The database file after the script has run. |
| `main.twal` | The write-ahead log after the script has run. |

All three are always written, even when the script changed nothing: `main.tdb`
is then a byte-for-byte copy of the input `main.tdb` (or a freshly initialised
single-page database if there was none), and `main.twal` is at least its 32-byte
header (§15.1). `main.twal` is never absent and never shorter than 32 bytes in
the output.

`results.txt` never contains a byte below `0x20` other than the LF line
separators, so the test runner compares it as text (ignoring trailing
whitespace); `main.tdb` and `main.twal` are compared byte for byte.

### 2.3 End of script

After the last command line has been processed:

1. If an explicit transaction is still open, it is **rolled back** (§13.4). No
   result block is produced for this.
2. No implicit checkpoint happens. Whatever the log holds at that moment is what
   `main.twal` contains.
3. The three output files are written.

---

## 3. CRC-32

Tessera uses one checksum everywhere: **CRC-32** with the reflected polynomial
`0xEDB88320` (the normal form is `0x04C11DB7`), initial value `0xFFFFFFFF`,
reflected input and output, and a final XOR of `0xFFFFFFFF`. Write it yourself;
do not call a library.

Bit-at-a-time definition:

```
crc32(data):
    crc = 0xFFFFFFFF
    for each byte b of data:
        crc = crc XOR b                  # low 8 bits
        repeat 8 times:
            if crc AND 1:
                crc = (crc >> 1) XOR 0xEDB88320
            else:
                crc = crc >> 1
    return crc XOR 0xFFFFFFFF
```

All arithmetic is on unsigned 32-bit values; `>>` is a logical shift.

Test vectors:

| Input | CRC-32 |
|---|---|
| empty string | `0x00000000` |
| `a` (one byte `0x61`) | `0xE8B7BE43` |
| `123456789` (ASCII) | `0xCBF43926` |
| `TESSERA1` (ASCII) | `0x2C9A9B66` |
| `TESSWAL1` (ASCII) | `0x7D446716` |
| 20 zero bytes | `0x0FD59B8D` |
| 1024 zero bytes | `0xEFB5AF2E` |

A CRC is always stored as a big-endian unsigned 32-bit integer.

---

## 4. The value model

A **value** is one of six kinds. The kind order below is the *type rank*, used
by comparisons (§17.2) and by the index key encoding (§14.1):

| Rank | Kind | Domain |
|---|---|---|
| 0 | `null` | the single value `null` |
| 1 | `bool` | `false`, `true` |
| 2 | `int` | signed 64-bit, `-9223372036854775808 .. 9223372036854775807` |
| 3 | `string` | a sequence of Unicode scalar values, held as UTF-8 bytes |
| 4 | `list` | an ordered sequence of values |
| 5 | `object` | a set of **fields**: distinct names (strings) each mapped to a value |

An object's fields have **no insertion order**: an object is a set of
(name, value) pairs, and it is always serialised, rendered and compared with its
fields in ascending byte-wise order of the UTF-8 of their names. Two object
literals that differ only in the order they list their fields denote the same
value and produce the same bytes.

A **document** is the value stored under a key. It may be of any kind, including
a scalar.

### 4.1 Depth

The depth of a value is 1 for `null`, `bool`, `int` and `string`; for a list or
object it is 1 plus the maximum depth of its elements or field values (1 for an
empty list or object). A document's depth must not exceed `MAX_DEPTH = 32`.

### 4.2 Serialisation

The stored form of a document is a byte string produced by `ser(v)`:

| Kind | Bytes |
|---|---|
| `null` | `0x00` |
| `false` | `0x01` |
| `true` | `0x02` |
| `int` | `0x03` followed by 8 bytes, the value in two's complement big-endian |
| `string` | `0x04`, then a 4-byte big-endian byte length `n`, then the `n` UTF-8 bytes |
| `list` | `0x05`, then a 4-byte big-endian element count `n`, then `ser` of each element in order |
| `object` | `0x06`, then a 4-byte big-endian field count `n`, then, for each field in ascending byte-wise name order: a 4-byte big-endian name byte length, the name's UTF-8 bytes, then `ser` of the field value |

Worked serialisations:

```
ser(1)                         = 03 00 00 00 00 00 00 00 01                (9 bytes)
ser(-1)                        = 03 ff ff ff ff ff ff ff ff                (9 bytes)
ser(null)                      = 00                                        (1 byte)
ser(true)                      = 02                                        (1 byte)
ser("")                        = 04 00 00 00 00                            (5 bytes)
ser("ada")                     = 04 00 00 00 03 61 64 61                   (8 bytes)
ser([1,"x",null])              = 05 00 00 00 03
                                 03 00 00 00 00 00 00 00 01
                                 04 00 00 00 01 78
                                 00                                        (21 bytes)
ser({name:"ada",age:36,ok:true}) =
    06 00 00 00 03
    00 00 00 03 61 67 65  03 00 00 00 00 00 00 00 24      # "age": 36
    00 00 00 04 6e 61 6d 65  04 00 00 00 03 61 64 61      # "name": "ada"
    00 00 00 02 6f 6b  02                                 # "ok": true
                                                                           (44 bytes)
```

(Note the fields come out sorted: `age`, `name`, `ok`.)

The serialised length of a document must not exceed `MAX_DOC = 65536` bytes.

### 4.3 Deserialisation

Deserialisation is the exact inverse. A database file produced by this
specification never contains an ill-formed document, so no error handling is
required.

### 4.4 Canonical rendering

`render(v)` turns a value into a single line of text for `results.txt`. There is
no whitespace anywhere in a rendered value.

| Kind | Rendering |
|---|---|
| `null` | `null` |
| `false` / `true` | `false` / `true` |
| `int` | decimal, a leading `-` for negatives, no `+`, no leading zeros; zero renders as `0` |
| `string` | `"` then the escaped text then `"` (§4.5) |
| `list` | `[`, the elements rendered and separated by `,`, `]`; `[]` when empty |
| `object` | `{`, then for each field in ascending byte-wise name order the rendered name (as a string), `:`, the rendered value, separated by `,`, then `}`; `{}` when empty |

Examples:

```
render(1)                        -> 1
render(-9223372036854775808)     -> -9223372036854775808
render([1,"x",null])             -> [1,"x",null]
render({name:"ada",age:36})      -> {"age":36,"name":"ada"}
render({})                       -> {}
render("a\"b")                   -> "a\"b"
```

### 4.5 String escaping on output

When rendering a string (a value, a key, or an object field name), each Unicode
scalar value is written as follows, in this priority order:

1. `"` (U+0022) → `\"`
2. `\` (U+005C) → `\\`
3. U+0008 → `\b`, U+0009 → `\t`, U+000A → `\n`, U+000C → `\f`, U+000D → `\r`
4. any other scalar below U+0020, and U+007F → `\u` followed by **four
   lowercase hex digits** of the scalar value (e.g. U+0000 → `\u0000`,
   U+001F → `\u001f`)
5. everything else → the scalar's own UTF-8 bytes, unescaped (so `é` and `😀`
   appear literally)

`/` is never escaped on output.

---

## 5. Keys, limits and constants

### 5.1 Keys

A **key** is a non-empty byte string of at most `MAX_KEY = 128` bytes. In the
command language a key is always written as a string literal, so its bytes are
the UTF-8 of the literal's text; a key is therefore always valid UTF-8, and may
contain any scalar value including U+0000 (written `\u0000`).

Keys are ordered by **unsigned byte-wise comparison**, with a proper prefix
sorting before the longer string. Formally, for keys `a` and `b`, compare
`a[i]` with `b[i]` as unsigned bytes for `i = 0, 1, …`; at the first difference
the smaller byte wins; if one runs out first it is the smaller. This is the
order used by the primary B+tree, by `scan`, and by every output that is "in key
order". It is *not* code-point order for anything other than ASCII — but since
UTF-8 preserves code-point order under byte-wise comparison, the two agree for
all valid UTF-8.

The same byte-wise order is used for index keys (§14.1), for object field names,
and for string comparison inside predicates (§17.2).

### 5.2 Constants

Every one of these is fixed by this specification. None is configurable and none
appears in the input.

| Name | Value | Meaning |
|---|---|---|
| `PAGE_SIZE` | `1024` | bytes per page |
| `MAX_KEY` | `128` | maximum primary key length in bytes |
| `MAX_INDEX_KEY` | `128` | maximum index key length in bytes (§14.1) |
| `MAX_INLINE` | `192` | document bytes held in a primary leaf cell (§11.3) |
| `OVF_PAYLOAD` | `1012` | document bytes held in one overflow page (§9) |
| `MAX_DOC` | `65536` | maximum serialised document length in bytes |
| `MAX_DEPTH` | `32` | maximum value nesting depth |
| `BTREE_HEADER` | `16` | bytes of page header on a B+tree page (§11.1) |
| `CAPACITY` | `1008` | `PAGE_SIZE - BTREE_HEADER`: payload bytes available on a B+tree page |
| `MIN_FILL` | `336` | the payload size below which a **deletion** triggers the repairs of §12.5 |
| `MAX_INDEXES` | `16` | directory slots for secondary indexes (§8) |
| `MAX_PATH` | `30` | maximum field-path length in bytes (§6.4) |
| `MAX_PATH_SEGMENTS` | `8` | maximum number of segments in a field path |
| `WAL_LIMIT` | `262144` | log size in bytes that triggers an automatic checkpoint (§15.7) |
| `MAX_LIMIT` | `2147483647` | largest accepted `limit` argument |

---

## 6. The command language

Each line of `commands.txt` is one command. A line is first turned into a token
stream (§6.1), then parsed against the grammar of §6.5. Whitespace between
tokens is insignificant; whitespace inside a string literal is part of the
string.

### 6.1 Tokens

The lexer reads the line left to right and produces tokens. Only two whitespace
bytes exist: space (`0x20`) and tab (`0x09`). They separate tokens and are
otherwise ignored, including at the start and end of the line. Every other byte
must begin a token.

| Token | Lexical rule |
|---|---|
| `WORD` | `[A-Za-z_][A-Za-z0-9_]*` |
| `INT` | `-?[0-9]+`; the `-`, when present, immediately precedes the first digit |
| `STRING` | `"` … `"` as described below |
| punctuation | one of `{` `}` `[` `]` `(` `)` `,` `:` `.` |
| operator | one of `==` `!=` `<=` `>=` `<` `>` |

The two-byte operators are matched greedily: `<=` is one token, never `<`
followed by `=`. A bare `=` is not a token. A bare `!` is not a token. A bare
`-` not followed by a digit is not a token.

The digit run of an `INT` is **maximal**: the lexer consumes every consecutive
digit. The resulting digit string must not have a redundant sign or leading
zero — it is either `0` or starts with `1`–`9`. So `0` is valid, while `007`,
`-0`, `-007` and `+1` are not tokens and make the line fail with `error syntax`
(`007` is read as the three-digit run `007` and then rejected; it is not read as
`0` followed by `07`).

Any byte that cannot begin a token, or a token that cannot be completed (an
unterminated string literal, `-` at end of line), makes the line fail with
`error syntax`.

#### String literals

A `STRING` token starts with `"` and ends at the next unescaped `"`. Between
them:

- A byte in `0x00`–`0x1F` is **not** allowed literally → `error syntax`.
- `\` starts an escape. The valid escapes are `\"`, `\\`, `\/`, `\b` (U+0008),
  `\f` (U+000C), `\n` (U+000A), `\r` (U+000D), `\t` (U+0009), and
  `\uXXXX` with exactly four hexadecimal digits in either case. Any other
  escape → `error syntax`.
- Any other byte is taken literally. `commands.txt` is valid UTF-8, so a
  literal multi-byte sequence carries through unchanged.

`\uXXXX` denotes a UTF-16 code unit. A high surrogate (`D800`–`DBFF`) must be
immediately followed by a `\uXXXX` escape holding a low surrogate
(`DC00`–`DFFF`); the pair denotes the corresponding scalar above U+FFFF. A high
surrogate not followed by a low-surrogate escape, and a low surrogate not
preceded by a high one, make the command fail with `error bad-utf8`. All other
values, including `\u0000`, are fine and denote that scalar, encoded as UTF-8 in
the token's value.

`error syntax` from the lexer takes precedence over `error bad-utf8`: the line is
tokenised first, and only when every token is lexically well formed are
surrogate pairs resolved. (`\ud800` alone is lexically fine, so it yields
`bad-utf8`; `\u00zz` is not a token at all, so it yields `syntax`.)

### 6.2 Keywords

There is no reserved-word list. A `WORD` token means whatever the grammar
position it appears in says it means. In a *value* position a `WORD` must be
exactly `null`, `true` or `false`; in a *path segment* position any `WORD` is a
segment name, including `null` or `and`; in a *command* or *option* position the
`WORD` must be one of the spellings the grammar allows there. Matching is
case-sensitive: `PUT` is not `put`.

### 6.3 Value literals

```ebnf
value   = "null" | "true" | "false" | INT | STRING | list | object ;
list    = "[" [ value { "," value } ] "]" ;
object  = "{" [ field { "," field } ] "}" ;
field   = name ":" value ;
name    = STRING | WORD ;
```

A `WORD` used as a field name denotes the string of its own characters, so
`{age:36}` and `{"age":36}` are the same value.

A trailing comma (`[1,]`, `{a:1,}`) is `error syntax`. An `INT` outside the
signed 64-bit range is `error int-range`. Two fields of one object with the same
name is `error dup-field`, raised as soon as the repeated name has been read,
before the token after it is examined (`{x:1,x}` and `{x:1,x 2}` are
`dup-field`, not `syntax`). A literal deeper than `MAX_DEPTH` is `error depth`.

Depth is checked while the literal is parsed, at one exact moment. The value
being parsed as a whole (the document of `put`, the value of `update`, the
right-hand side of a comparison) is at **level 1**; an element of a list at
level `k`, and a field value of an object at level `k`, is at level `k+1`.
Whenever the parser is about to read a value at level 33 — after a `[` that is
not immediately followed by `]`, after a `,` inside a list, or after a field's
`:`, in each case inside a container at level 32 — the command fails with
`error depth` at once, **before the token in that position is examined**, even
if that token is missing, malformed or would itself be an error. So, with
`[`×32 meaning thirty-two opening brackets:

- `[`×32 then `]`×32 is fine (the innermost value is an empty list at level 32);
- `[`×32 then `1` then `]`×32 is `depth`, and so is `[`×32 followed by
  `99999999999999999999`, by `"\ud800"`, by `,`, by `)` or by nothing at all;
- `[`×30 then `{x:[[1]],x:1}` is `depth` (the `1` inside `[[1]]` is at level 33
  and comes before the repeated `x`), while `[`×30 then `{x:1,x:[[1]]}` is
  `dup-field`.

Lexing still comes first (§18.2): `[`×32 followed by a lone `-` is `syntax`.

### 6.4 Field paths

```ebnf
path    = WORD { "." WORD } ;
```

The path's **text** is its segments joined by `.`; that text is what is stored
in the index directory and printed in results. Whitespace around the dots is
allowed in the input and does not appear in the text (`a . b` has the text
`a.b`).

A path must have at most `MAX_PATH_SEGMENTS = 8` segments and its text must be
at most `MAX_PATH = 30` bytes; otherwise `error bad-path`.

Both limits are checked **as each segment is consumed**, starting with the
first segment, so that the error is reported at the first segment that breaks
one, in source order (§18.2): a single segment of 31 bytes is `bad-path` even
when a stray `.` or a missing value follows it; the
ninth segment of `a.b.c.d.e.f.g.h.i.` is `bad-path`, not `syntax` for the
trailing dot, and a path whose text passes 30 bytes at its fourth segment is
`bad-path` whatever follows it.

Resolving a path against a document: start with the document; for each segment
in order, if the current value is an object that has a field with exactly that
name, continue with that field's value, otherwise the path is **missing**. A
list is never traversed by a path segment (there is no numeric indexing), so a
path into a list is missing.

### 6.5 Commands

```ebnf
command = "begin"
        | "commit"
        | "rollback"
        | "checkpoint"
        | "stat"
        | "indexes"
        | "put"    STRING value
        | "get"    STRING
        | "delete" STRING
        | "update" STRING path value
        | "unset"  STRING path
        | "scan"   { scanopt }
        | "find"   pred [ "limit" INT ]
        | "create" "index" path
        | "drop"   "index" path ;

scanopt = "from" STRING | "to" STRING | "limit" INT
        | "reverse" | "keys" ;
```

No command may be followed by extra tokens; a leftover token is `error syntax`.
A line whose first token is a `WORD` that is none of the fifteen command
spellings above is `error unknown-command`. A line that produces no tokens at
all (empty, or only spaces and tabs) and a line whose first token is not a
`WORD` are `error syntax`.

#### `scan` options

Each option may appear at most once; a repeat is `error syntax`. Options may
appear in any order.

- `from <bound>` — inclusive lower bound. Absent: unbounded below.
- `to <bound>` — **exclusive** upper bound. Absent: unbounded above.
- `limit <n>` — at most `n` results. Absent: no limit. `n` must satisfy
  `0 ≤ n ≤ MAX_LIMIT = 2147483647`; anything else, including a negative
  `INT`, is `error syntax`. The same range applies to `find`'s `limit`.
- `reverse` — emit results in descending key order instead of ascending.
- `keys` — emit only the keys, not the documents.

`from` and `to` take a **bound**, not a key: a bound is any byte string the
string literal can denote, compared against keys with the byte-wise order of
§5.1, and it is **not** subject to the key length rules. A bound need not be a
possible key: `scan from ""` is accepted and selects everything, since the empty
string sorts below every key, and so is a bound of more than `MAX_KEY` bytes,
which is simply compared byte for byte like any other bound. `error bad-key` is
therefore never raised by `scan`.

The `limit` value is resolved as an ordinary `INT` first, so an `INT` token
outside the signed 64-bit range is `error int-range` (§18.2 stage 3) and only a
value that *is* a 64-bit integer but falls outside `0 … MAX_LIMIT` is
`error syntax`.

`from` and `to` keep their meaning under `reverse`: the selected set is always
`{ k : from ≤ k < to }`, and `reverse` only changes the order the selected keys
come out in. `limit` is applied **after** ordering, so `scan limit 3 reverse`
returns the three greatest keys, in descending order.

If `from` ≥ `to` the result is empty (not an error).

#### `find`

`find <pred> [limit <n>]` evaluates a predicate against every document and emits
the matches **in ascending primary key order**, whatever plan was used.
`limit <n>` is applied after that ordering. The predicate grammar and semantics
are §17.

#### Transaction commands

- `begin` — opens an explicit transaction. `error txn-active` if one is open.
- `commit` — commits the open explicit transaction. `error no-txn` if none.
- `rollback` — discards it. `error no-txn` if none.
- `checkpoint` — performs a checkpoint (§15.6). `error txn-active` if a
  transaction is open.

#### Index commands

- `create index <path>` — builds a secondary index on `path` (§14.4).
- `drop index <path>` — removes it (§14.5).
- `indexes` — lists the live indexes.

#### Read-only commands

`get`, `scan`, `find`, `stat` and `indexes` never modify anything and never
start a transaction.

---

## 7. The database file

### 7.1 Pages

The database file is a sequence of **pages** of exactly `PAGE_SIZE = 1024`
bytes. Pages are numbered from 1: page `p` occupies bytes
`(p-1)*1024 .. p*1024-1`. The file's length is always exactly
`page_count * 1024`, where `page_count` is the field of the same name in the
header page. The file is never truncated or shortened; `page_count` never
decreases.

Page 1 is the **header page** and holds no tree data. Every other page is one
of: a B+tree interior page, a primary leaf page, an index leaf page, an overflow
page, or a free page. The first byte of a page is its **type byte**:

| Type byte | Page kind | Section |
|---|---|---|
| `0` | free | §10 |
| `1` | primary leaf | §11.3 |
| `2` | interior | §11.4 |
| `3` | overflow | §9 |
| `5` | index leaf | §11.5 |

Type `4` is unused and never appears. Page 1 has no type byte (its first bytes
are the magic).

**All multi-byte integers anywhere in the file and in the log are unsigned
big-endian**, except document integers, which are two's complement big-endian
(§4.2).

### 7.2 The header page

Page 1, bytes 0–1023:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 8 | `magic` | the ASCII bytes `TESSERA1` (`54 45 53 53 45 52 41 31`) |
| 8 | 2 | `format_version` | `1` |
| 10 | 2 | `page_size` | `1024` |
| 12 | 4 | `page_count` | number of pages in the file, ≥ 1 |
| 16 | 4 | `freelist_head` | first page of the free list, `0` when the list is empty |
| 20 | 4 | `freelist_count` | number of pages on the free list |
| 24 | 4 | `primary_root` | root page of the primary B+tree, `0` when the store is empty |
| 28 | 4 | `primary_count` | number of documents in the store |
| 32 | 8 | `commit_counter` | number of transactions committed over the lifetime of the database |
| 40 | 4 | `index_count` | number of live entries in the index directory |
| 44 | 84 | — | reserved, **all zero** |
| 128 | 768 | `directory` | 16 index directory slots of 48 bytes (§8) |
| 896 | 128 | — | reserved, **all zero** |

There is no checksum on the header page; integrity of an in-progress change is
the log's job.

Page 1 is canonical in the same sense as a B+tree page (§11): its 1024 bytes are
a pure function of the fields in the table above, because every other byte of it
is reserved and zero. Writing page 1 from those fields and patching a field of
the page in place therefore produce the same bytes, and an unchanged header page
is reproduced exactly.

A freshly committed single-document database has this header page (bytes 0–47;
bytes 48–1023 are all zero):

```
00000000  54 45 53 53 45 52 41 31 00 01 04 00 00 00 00 02
00000010  00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 01
00000020  00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00
```

— magic, version 1, page size `0x0400`, `page_count = 2`, no free pages,
`primary_root = 2`, `primary_count = 1`, `commit_counter = 1`, `index_count = 0`.

### 7.3 A fresh database

When the input directory has no `main.tdb` (or it is zero bytes long), the
engine starts from a **fresh database**: a single page, page 1, with

```
page_count = 1, freelist_head = 0, freelist_count = 0,
primary_root = 0, primary_count = 0, commit_counter = 0, index_count = 0,
all 16 directory slots unused, every reserved byte zero
```

so the whole 1024-byte page is

```
00000000  54 45 53 53 45 52 41 31 00 01 04 00 00 00 00 01
00000010  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
...       (bytes 0x20 .. 0x3ff are all zero)
```

If the script then does nothing that writes, the output `main.tdb` is exactly
these 1024 bytes.

---

## 8. The index directory

The header page holds 16 fixed-size slots describing the secondary indexes.
Slot `s` (0-based) occupies bytes `128 + 48*s .. 128 + 48*s + 47`:

| Offset in slot | Size | Field |
|---|---|---|
| 0 | 1 | `live` — `1` for a live index, `0` for an unused slot |
| 1 | 1 | `path_len` — length in bytes of the path text, `1..30` |
| 2 | 30 | `path` — the path text in UTF-8, **zero-padded** to 30 bytes |
| 32 | 4 | `root` — root page of the index B+tree, `0` when the index is empty |
| 36 | 4 | `entries` — number of entries in the index |
| 40 | 8 | — reserved, **all zero** |

An unused slot is 48 zero bytes. Dropping an index zeroes its whole slot.

`create index` uses the **lowest-numbered unused slot**. Slots are never
compacted or renumbered, so after `create index a`, `create index b`,
`drop index a`, `create index c`, index `c` sits in slot 0 and `b` in slot 1.
`index_count` is the number of live slots.

Whenever this document says "for each live index, in slot order", it means
ascending slot number.

A slot with one index on `age` (root page 4, one entry) reads:

```
00000080  01 03 61 67 65 00 00 00 00 00 00 00 00 00 00 00
00000090  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
000000a0  00 00 00 04 00 00 00 01 00 00 00 00 00 00 00 00
```

---

## 9. Overflow pages

A document longer than `MAX_INLINE = 192` bytes keeps its first 192 serialised
bytes in the leaf cell and the rest in a chain of overflow pages. An overflow
page is:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type byte `3` |
| 1 | 3 | zero |
| 4 | 4 | `next` — next overflow page, `0` on the last page of the chain |
| 8 | 2 | `payload_len` — `1..1012` |
| 10 | 2 | zero |
| 12 | 1012 | payload; bytes after `payload_len` are **zero** |

The chain carries the document bytes from offset 192 onward, split into
`OVF_PAYLOAD = 1012`-byte chunks in order. Every chunk but the last is exactly
1012 bytes; the last holds the remainder, which is `1..1012` bytes. There is
never an empty overflow page and never a chain for a document of 192 bytes or
fewer.

The number of overflow pages for a document of serialised length `L > 192` is
`ceil((L - 192) / 1012)`.

An overflow page holding the five bytes `ZZZZZ` as the last page of a chain:

```
00000000  03 00 00 00 00 00 00 00 00 05 00 00 5a 5a 5a 5a
00000010  5a 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
...       (zero to the end of the page)
```

Pages of a new chain are allocated (§10) in chain order: first chunk first.
Pages of a chain being discarded are freed in chain order too: first chunk
first, so the **last** page of the chain ends up at the head of the free list.

---

## 10. Free pages and the free list

A free page is 1024 bytes laid out as:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type byte `0` |
| 1 | 3 | zero |
| 4 | 4 | `next` — the next free page, `0` at the end of the list |
| 8 | 1016 | zero |

So a free page whose successor is page 7 is

```
00000000  00 00 00 00 00 00 00 07 00 00 00 00 00 00 00 00
...       (zero to the end of the page)
```

The free list is a **LIFO stack** rooted at `freelist_head`.

```
allocate_page():
    if freelist_head != 0:
        p = freelist_head
        freelist_head = next(p)                 # read from page p
        freelist_count = freelist_count - 1
        return p                                # caller overwrites the whole page
    page_count = page_count + 1
    return page_count                           # a brand-new page past the old end of file

free_page(p):
    write page p as a free page with next = freelist_head
    freelist_head = p
    freelist_count = freelist_count + 1
```

Both operations modify the header page, so page 1 becomes dirty.

A page freed during a transaction **may be reallocated by the same
transaction**, immediately, by the rule above. No page is ever reused while it
is still reachable from a tree.

Freed pages are never reclaimed by shrinking the file, and the free list is
never sorted, compacted or rebuilt.

---

## 11. Canonical B+tree pages

This section is the reason two implementations agree byte for byte.

**Every B+tree page is always stored in canonical form.** A page's 1024 bytes
are a pure function of its logical content — the ordered list of cells plus the
one pointer in its header. Whenever a page is modified, it is re-encoded from
scratch by the rule below; there is no in-page free-space list, no fragmentation
and no incremental edit of a page image. Reading a page and writing it back
unchanged must reproduce the same bytes.

### 11.1 Shared page header

Bytes 0–15 of every interior, primary-leaf and index-leaf page:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type byte: `1` primary leaf, `2` interior, `5` index leaf |
| 1 | 1 | zero |
| 2 | 2 | `cell_count` — number of cells on the page |
| 4 | 2 | `cell_start` — byte offset of the first cell (see §11.2); `1024` when `cell_count` is 0 |
| 6 | 2 | zero |
| 8 | 4 | `link` — for an interior page the **rightmost child** page number; for a leaf page the **next leaf** in ascending key order, or `0` if it is the last leaf |
| 12 | 4 | zero |

### 11.2 Canonical encoding

Let the page hold cells `c[0] … c[n-1]`, **in ascending key order**, with
encoded sizes `s[0] … s[n-1]`. Then:

- bytes 0–15 are the header of §11.1, with `cell_count = n`;
- bytes `16 .. 16+2n-1` are the **cell pointer array**: `n` big-endian 16-bit
  offsets, pointer `i` giving the offset of cell `i`. The array is in key order,
  so the pointers are strictly increasing;
- `cell_start = 1024 - (s[0] + … + s[n-1])`, and cell `i` starts at
  `cell_start + s[0] + … + s[i-1]`. The cells are therefore packed
  contiguously, in key order, ending exactly at byte 1023;
- every byte between the end of the pointer array (`16+2n`) and `cell_start` is
  **zero**.

The **payload size** of a page is `used(page) = 2n + s[0] + … + s[n-1]`. A page
is valid when `used(page) ≤ CAPACITY = 1008`. A page **overflows** when a
modification would make `used > 1008`; a non-root page **underflows** when a
deletion leaves `used < MIN_FILL = 336`.

`used ≤ 1008` is an invariant: an overfull page is never stored, so it never has
1024 bytes at all — a page that overflows is split (§12.3) and only the two
halves are written. `used ≥ MIN_FILL` is **not** an invariant; see §12.5.

An empty page (`n = 0`) is: the header with `cell_count = 0` and
`cell_start = 1024`, then 1008 zero bytes.

### 11.3 Primary leaf cells

A primary leaf page (type `1`) holds one cell per document:

| Offset in cell | Size | Field |
|---|---|---|
| 0 | 2 | `key_len` — `1..128` |
| 2 | 4 | `doc_len` — total serialised document length, `0..65536` |
| 6 | 2 | `inline_len` — document bytes stored here, `min(doc_len, 192)` |
| 8 | 4 | `overflow` — first overflow page, `0` when `inline_len == doc_len` |
| 12 | `key_len` | the key bytes |
| 12+`key_len` | `inline_len` | the first `inline_len` serialised document bytes |

Cell size `= 12 + key_len + inline_len`, at most `12 + 128 + 192 = 332`.

A leaf page with one cell, key `a`, document `1` (9 bytes, §4.2), and no next
leaf:

```
00000000  01 00 00 01 03 ea 00 00 00 00 00 00 00 00 00 00
00000010  03 ea 00 00 00 00 00 00 00 00 00 00 00 00 00 00
...       (zero from byte 0x12 to byte 0x3e9)
000003e0  00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 09
000003f0  00 09 00 00 00 00 61 03 00 00 00 00 00 00 00 01
```

Type `1`, `cell_count = 1`, `cell_start = 0x03ea = 1002`, `link = 0`, one
pointer `0x03ea`, then at 1002 the cell: `key_len = 1`, `doc_len = 9`,
`inline_len = 9`, `overflow = 0`, key `61`, document
`03 00 00 00 00 00 00 00 01`. `used = 2 + 22 = 24`.

### 11.4 Interior cells

An interior page (type `2`) holds `n` separator cells and `n+1` children: cell
`i`'s `child`, for `i = 0 … n-1`, plus the header's `link` as the rightmost
child.

| Offset in cell | Size | Field |
|---|---|---|
| 0 | 2 | `key_len` — `1..128` |
| 2 | 4 | `child` — child page number |
| 6 | `key_len` | the separator key bytes |

Cell size `= 6 + key_len`, at most `134`.

**Separator convention.** Separator keys `k[0] < k[1] < … < k[n-1]` are *high
keys*: the subtree under `child[i]` contains only keys `≤ k[i]`, and the subtree
under `link` contains only keys `> k[n-1]`. Descending for a target key `t`:
take the smallest `i` with `t ≤ k[i]` and descend `child[i]`; if there is no
such `i`, descend `link`.

A separator is an **upper bound**, not necessarily a key that exists. Deleting
the key that a separator was copied from does not change the separator;
separators change only through the split and rebalance rules of §12.

An interior page with one separator `m` over child 2, rightmost child 3:

```
00000000  02 00 00 01 03 f9 00 00 00 00 00 03 00 00 00 00
00000010  03 f9 00 00 00 00 00 00 00 00 00 00 00 00 00 00
...       (zero from byte 0x12 to byte 0x3f8)
000003f0  00 00 00 00 00 00 00 00 00 00 01 00 00 00 02 6d
```

### 11.5 Index leaf cells

An index leaf page (type `5`) holds one cell per index entry and no payload:

| Offset in cell | Size | Field |
|---|---|---|
| 0 | 2 | `key_len` — `1..128` |
| 2 | `key_len` | the index key bytes (§14.1) |

Cell size `= 2 + key_len`, at most `130`.

Index trees use type `2` interior pages with exactly the same interior cell
format and the same separator convention as the primary tree. The `link` field
of an index leaf is the next index leaf in ascending index-key order.

An index leaf with the two entries `vkey(29)‖"u2"` and `vkey(36)‖"u1"`
(11 bytes each, §14.1):

```
00000000  05 00 00 02 03 e6 00 00 00 00 00 00 00 00 00 00
00000010  03 e6 03 f3 00 00 00 00 00 00 00 00 00 00 00 00
...       (zero from byte 0x14 to byte 0x3e5)
000003e0  00 00 00 00 00 00 00 0b 30 80 00 00 00 00 00 00
000003f0  1d 75 32 00 0b 30 80 00 00 00 00 00 00 24 75 31
```

`cell_count = 2`, `cell_start = 0x03e6 = 998`, pointers `0x03e6` and `0x03f3`,
`used = 4 + 26 = 30`.

### 11.6 Maximum cell cost

The **cost** of a cell is its size plus the 2 bytes of its pointer. The largest
possible cost is 334 on a primary leaf, 136 on an interior page and 132 on an
index leaf. These bounds, together with `CAPACITY = 1008` and `MIN_FILL = 336`,
guarantee that every split, every merge and every borrowed cell in §12 fits;
implementations do not need to handle a cell that will not fit on a page. (A
borrow can still make the **parent** overflow by lengthening a separator; that
parent is split like any other overflowing page, §12.5.)

---

## 12. B+tree algorithms

There are two kinds of tree: the **primary tree** (type `1` leaves, cells of
§11.3, keyed by the document key) and an **index tree** (type `5` leaves, cells
of §11.5, keyed by the index key of §14.1). Both use type `2` interior pages and
behave identically; "the tree's root field" means `primary_root` in the header
for the primary tree, and the directory slot's `root` for an index tree.

All of §12 is about the logical content of pages; each modified page is then
re-encoded canonically (§11.2).

### 12.1 Search

To find `key`:

1. `p = root`. If `p == 0` the tree is empty and the key is absent.
2. While page `p` is an interior page: take the smallest cell index `i` with
   `key ≤ k[i]`; `p = child[i]`. If no such `i` exists, `p = link`.
3. Page `p` is a leaf. Scan its cells for one whose key equals `key`.

Within a page, cells are in ascending key order, so binary search is available
but not required.

The **path** of a search is the sequence of (interior page, chosen child index)
pairs visited, where the chosen child index is `i` for `child[i]` and `n` for
`link`. The path is needed by insert and delete.

### 12.2 Insert and replace

To store a cell with key `key`:

1. If the tree's root field is `0`: `r = allocate_page()`, write page `r` as an
   empty leaf of the tree's leaf kind (`link = 0`), set the root field to `r`.
2. Descend to the leaf, recording the path.
3. If the leaf already has a cell with this key, **replace it in place** — the
   new cell takes the same position in the key order. Otherwise insert the new
   cell at its sorted position.
4. Re-encode the leaf. If `used(leaf) > 1008`, split it (§12.3).

A replace never triggers underflow handling, even when the new cell is much
smaller than the old one. **Underflow is only ever triggered by a deletion**
(§12.4).

### 12.3 Splitting

#### The split point

Let the overflowing page hold cells `c[0] … c[n-1]` with costs
`w[i] = size(c[i]) + 2`, and let `T = w[0] + … + w[n-1]` (this is `used`, which
is `> 1008`). Define prefix sums `P[j] = w[0] + … + w[j-1]`, so `P[0] = 0`.

> **`m` is the smallest index in `1 … n-1` with `2 * P[m] ≥ T`.**

With `T > 1008` and the cost bounds of §11.6, such an `m` always exists and is
always at least 2, so neither side of a split is ever empty.

#### Leaf split

Cells `c[0] … c[m-1]` stay on the original page; cells `c[m] … c[n-1]` move to a
**newly allocated** page. The original page keeps its page number — this matters
for byte identity.

```
right = allocate_page()
write page `right` as a leaf of the same kind holding c[m] … c[n-1],
      with link = link(left)
set link(left) = right, and leave c[0] … c[m-1] on `left`
separator = key of c[m-1]            # the largest key still on the left page
```

#### Interior split

Cell `c[m-1]` is **promoted**: its key becomes the separator handed to the
parent and its child becomes the left page's new rightmost child.

```
right = allocate_page()
write page `right` as an interior page holding c[m] … c[n-1],
      with link = link(left)
set link(left) = child(c[m-1])
left keeps c[0] … c[m-2]
separator = key of c[m-1]
```

(With `m ≥ 2`, the left page keeps at least one cell.)

#### Installing the separator in the parent

Let `left` be the page that was split, `right` the new page and `sep` the
separator key.

- If `left` was the tree's root: `newroot = allocate_page()` (allocated **after**
  `right`), written as an interior page with the single cell `(sep, left)` and
  `link = right`. The tree's root field becomes `newroot`. The tree's height
  grows by one.
- Otherwise let `parent` be the page above `left` on the path and `j` the child
  index taken there.
  - If `j == n_parent` (`left` was reached through `link`): append the cell
    `(sep, left)` at the end of the parent's cells and set
    `link(parent) = right`.
  - Otherwise: set `child(c_parent[j]) = right` and insert the cell
    `(sep, left)` immediately before it, at index `j`.

  Then re-encode the parent; if `used(parent) > 1008`, split the parent the same
  way, and so on up the path. Each split allocates its new sibling at the moment
  that split happens, so allocation proceeds strictly bottom-up, and the new root
  page (if any) is allocated last.

`sep` is always strictly smaller than the separator it is inserted before, so
interior separator keys stay strictly increasing. The reason is that the right
half of a split is never empty (§12.3): every key on `right` is greater than
`sep` and still lies in the subtree the parent's cell `j` covers, so
`sep < k_parent[j]`. Likewise every key on `left` is greater than
`k_parent[j-1]`, so `k_parent[j-1] < sep`.

### 12.4 Deletion

To delete `key`:

1. Descend to the leaf, recording the path. If the key is not there the caller
   reports `error not-found`; nothing is modified.
2. Remove the cell from the leaf and re-encode it.
3. If the leaf is the tree's root:
   - if it still has cells, done;
   - if it is now empty, `free_page(leaf)` and set the tree's root field to `0`.
4. Otherwise, if `used(leaf) ≥ MIN_FILL = 336`, done.
5. Otherwise the leaf underflows: apply §12.5.

### 12.5 Underflow: borrow, then merge

Let `N` be the underflowing page, `P` its parent and `j` the child index of `N`
in `P` (`j = n_P` when `N` is `P`'s `link`).

**What is and is not guaranteed about fill.** `MIN_FILL` is only the threshold
that makes a deletion trigger this section; it is *not* a lower bound a stored
page obeys. A page can legitimately sit below `MIN_FILL`, in two ways: a replace
never triggers underflow handling (§12.2), so replacing a large document with a
small one can leave a leaf far below 336; and a borrow hands `N` exactly one
cell, which need not bring `used(N)` up to 336 — the repair still stops there,
because the parent's cell count did not change. Implementations must therefore
not assert `used ≥ MIN_FILL` anywhere, and must not re-repair a page that is
still thin after a borrow.

What *is* guaranteed is that **every non-root page holds at least one cell**
whenever an operation has finished: only a deletion removes a cell, a deletion
that empties a non-root page leaves `used = 0 < MIN_FILL` and so is repaired at
once, and the repair either gives the page a cell (borrow) or makes the page
disappear (merge). Consequently `P` always has at least two children when this
section runs, `N` always has a sibling under `P`, and the sibling tests below
always have a last or first cell to look at.

- `L` is the left sibling: `child[j-1]` if `j ≥ 1`, otherwise none. Its
  separator in `P` is `k[j-1]`.
- `R` is the right sibling: `child[j+1]` if `j+1 ≤ n_P-1`, or `link` if
  `j+1 == n_P`; none if `j == n_P`. The separator between `N` and `R` is `k[j]`.

The four repairs are tried **strictly in this order**, and the first one that
applies is the one used:

1. **borrow from the left** — `L` exists and `used(L)` minus the cost of its
   last cell is still `≥ MIN_FILL`;
2. **borrow from the right** — `R` exists and `used(R)` minus the cost of its
   first cell is still `≥ MIN_FILL`;
3. **merge with the left** — `L` exists;
4. **merge with the right** — `R` exists.

(When both borrows fail the merge always fits on one page, so no further case is
needed. The reason: `used(N) ≤ 335` because `N` underflowed, and a failed borrow
from `L` means `used(L) < MIN_FILL + cost of L's last cell ≤ 336 + 334 = 670`,
so a leaf merge reaches at most `1004 ≤ 1008`; for interior pages the bound is
`336 + 136` plus the one promoted cell of at most 136, which is smaller still.
The same arithmetic covers merging with `R`. This holds whatever `used(L)` or
`used(R)` happens to be, so it survives the thin pages described above.)

#### Borrow from the left

*Leaf:* move `L`'s last cell to the front of `N`'s cells. Set
`k[j-1] = ` the key of `L`'s new last cell.

*Interior:* prepend to `N` the cell `(k[j-1], link(L))`. Then set
`k[j-1] = ` the key of `L`'s last cell, set `link(L) = child` of `L`'s last
cell, and remove that last cell from `L`.

#### Borrow from the right

*Leaf:* move `R`'s first cell to the end of `N`'s cells. Set `k[j] = ` the key
of that moved cell (it is now `N`'s largest key).

*Interior:* append to `N` the cell `(k[j], link(N))`. Then set
`link(N) = child` of `R`'s first cell, set `k[j] = ` the key of `R`'s first
cell, and remove that first cell from `R`.

In both borrow cases `L` or `R` and `N` are rewritten, and then `P` is stored
exactly as an insert stores a page (§12.2 step 4, §12.3): re-encoded if
`used(P) ≤ 1008`, and otherwise **split**, with the separator installed in
`P`'s own parent and splits cascading up the path (a new root if `P` was the
root). This overflow is possible because the separator that changes in `P` can
grow — a borrow can replace a 4-byte separator with a 128-byte key, and a parent
already holding more than `1008 - 124` bytes of payload then overflows. When `P`
does not overflow, exactly three tree pages are rewritten and no page is
allocated or freed. Either way the parent's cell count does not drop, so a
borrow never triggers further **underflow** handling above.

#### Merge with the left

The **left page survives**; `N` is freed.

*Leaf:* append all of `N`'s cells to `L`; set `link(L) = link(N)`.

*Interior:* append to `L` the cell `(k[j-1], link(L))`, then append all of `N`'s
cells, then set `link(L) = link(N)`.

Then, in `P`: remove cell `j-1` (the one holding `k[j-1]`, whose child was `L`),
and make the slot that pointed to `N` point to `L` instead — that is, if
`j == n_P` set `link(P) = L`, otherwise set the child of the cell that was at
index `j` (now at index `j-1`) to `L`. Finally `free_page(N)`.

#### Merge with the right

`N` **survives**; `R` is freed.

*Leaf:* append all of `R`'s cells to `N`; set `link(N) = link(R)`.

*Interior:* append to `N` the cell `(k[j], link(N))`, then append all of `R`'s
cells, then set `link(N) = link(R)`.

Then, in `P`: remove cell `j` (the one holding `k[j]`, whose child was `N`), and
make the slot that pointed to `R` point to `N` — if `R` was `link(P)` set
`link(P) = N`, otherwise set the child of the cell that was at index `j+1` (now
at index `j`) to `N`. Finally `free_page(R)`.

#### Propagating upward

A merge removes a cell from `P`, so after re-encoding `P`:

- if `P` is the tree's root and now has **zero** cells, the tree's height
  shrinks: the root field becomes `link(P)` and `free_page(P)`;
- else if `P` is the root, done;
- else if `used(P) ≥ MIN_FILL`, done;
- else `P` underflows: apply §12.5 to `P` with its own parent, and so on.

An interior page may legitimately hold zero cells for the short time between a
merge and its own repair; search handles that (step 2 of §12.1 descends `link`).
It can never be left that way at the end of an operation unless it is the root,
and a zero-cell root is collapsed immediately as above.

### 12.6 Traversal order

Three orders are used by this specification and must be implemented exactly:

- **Key order** — follow the leaf chain. Find the leftmost leaf by descending
  `child[0]` from the root, then walk `link` from leaf to leaf, taking each
  leaf's cells in order. Used by `scan`, by `find` with a scan plan, by
  `create index`, and whenever "in key order" is written.
- **Reverse key order** — the same sequence, reversed. (Leaves have no backward
  pointer; descend the tree or buffer, as you like — it is not observable.)
- **Post-order page order** — for freeing a whole tree (§14.5): recursively
  visit `child[0] … child[n-1]` then `link`, then the page itself. So a page is
  always freed after every page below it, and children are freed left to right.

### 12.7 Height

The height of a tree is 0 when its root field is `0`, 1 when the root is a leaf,
and 1 + the height of any child when the root is an interior page. All leaves
are at the same depth.

---

## 13. Transactions and the page cache

Tessera never writes to `main.tdb` during normal operation. A committed change
lives in the log until a checkpoint copies it across (§15.6). Reads therefore go
through an **overlay**.

### 13.1 Reading a page

```
read_page(p):
    if p is in the dirty set of the open transaction:   return that image
    if p has a committed image in the log overlay:      return the newest one
    if p <= page_count_of_main_file:                    return bytes from main.tdb
    return 1024 zero bytes                              # cannot happen for a reachable page
```

The **log overlay** is the map from page number to the newest committed image of
that page in the log, built when the database is opened (§16) and extended by
every commit. A checkpoint empties it.

### 13.2 Writing a page

A write marks the page dirty in the open transaction and stores its new 1024
bytes. Nothing reaches the log or the file until commit. A page is dirty because
it was **written**, not because its bytes changed: re-encoding a page to exactly
the bytes it already held still makes it dirty, and it still gets a page image
record at commit. (This happens for instance when `put` replaces a document with
an identical one.) The engine's header
fields (`page_count`, `freelist_head`, `freelist_count`, `primary_root`,
`primary_count`, `commit_counter`, `index_count`, the directory) are **the
contents of page 1**: changing any of them dirties page 1, and discarding page 1
on rollback restores all of them.

A page allocated past the end of the file (`allocate_page` taking the
`page_count + 1` branch) exists only in the cache until commit; `page_count`
rises with it and falls again on rollback.

### 13.3 Explicit and implicit transactions

`begin` opens an explicit transaction; `commit` and `rollback` end it.

Each of the six writing commands — `put`, `delete`, `update`, `unset`,
`create index`, `drop index` — runs inside an **implicit transaction** when no
explicit transaction is open: the command's changes are made and committed
immediately, exactly as if `begin` and `commit` surrounded it.

If a command fails with any error (§18), **nothing is modified**: no page is
dirtied, `commit_counter` does not move, nothing is appended to the log, and an
implicit transaction is not started. Inside an explicit transaction a failing
command leaves the transaction open and otherwise untouched; it does not abort
it.

### 13.4 Commit and rollback

**Commit** (explicit or implicit):

1. `commit_counter = commit_counter + 1` — page 1 becomes dirty, so a commit
   always writes at least one page frame. Call the new value `txn_id`.
2. Append one page-image record (§15.2) per dirty page to the log, in
   **ascending page-number order**, each carrying `txn_id`.
3. Append one commit record carrying `txn_id` and the number of page frames just
   written.
4. Merge the dirty images into the log overlay, clear the dirty set, close the
   transaction.
5. If the log's size in bytes is now `≥ WAL_LIMIT = 262144`, perform a
   checkpoint immediately (§15.7).

**Rollback:** discard the dirty set, close the transaction. Nothing is appended
to the log; `commit_counter` keeps the value it had before `begin`. A rollback
is invisible in both output files except through the absence of the changes.

An explicit transaction still open when `commands.txt` runs out is rolled back
(§2.3).

### 13.5 What a transaction does not do

- There is no nesting: `begin` inside a transaction is `error txn-active`.
- There is no savepoint and no partial rollback.
- `checkpoint` inside a transaction is `error txn-active`.
- `get`, `scan`, `find`, `stat` and `indexes` inside a transaction see the
  transaction's own uncommitted changes (they read through the dirty set).

---

## 14. Secondary indexes

An index maps the value of one field path to the keys of the documents that have
it. Up to `MAX_INDEXES = 16` indexes exist at once, described by the directory
of §8 and stored one B+tree each.

### 14.1 Index key encoding

An index entry's key is

```
index_key = vkey(value) ‖ document_key
```

where `vkey` is an order-preserving, self-delimiting encoding of the field value
and `document_key` is the primary key's bytes appended raw. Because `vkey` is
self-delimiting, byte-wise comparison of `index_key`s orders entries by field
value first and by document key second, and the document key can be recovered by
decoding `vkey` and taking the remainder.

All bytes in this table and in the worked `vkey`s below are written in
hexadecimal (`10` is the byte 0x10).

| Value | `vkey` |
|---|---|
| `null` | `10` |
| `false` | `20` |
| `true` | `21` |
| int `v` | `30` followed by 8 bytes: the two's complement big-endian encoding of `v` with its top bit flipped (equivalently `v + 2^63` as an unsigned 64-bit big-endian integer) |
| string `s` | `40`, then the UTF-8 bytes of `s` with every `00` byte replaced by the two bytes `00 FF`, then the terminator `00 00` |

Lists and objects have **no** `vkey`: a document whose field value at the
indexed path is a list or an object is **not indexed**, exactly as if the field
were missing. A document in which the path is missing is not indexed either.

The type tags `10 < 20 < 21 < 30 < 40` make the index order null < false < true
< ints < strings, and within each type the encoding is order-preserving: the
flipped top bit maps the signed order onto the unsigned order, and the string
escape makes `00 00` sort below any continuation byte so that a proper prefix
sorts first.

Worked `vkey`s:

```
vkey(null)                       = 10
vkey(false)                      = 20
vkey(true)                       = 21
vkey(0)                          = 30 80 00 00 00 00 00 00 00
vkey(36)                         = 30 80 00 00 00 00 00 00 24
vkey(-1)                         = 30 7f ff ff ff ff ff ff ff
vkey(-9223372036854775808)       = 30 00 00 00 00 00 00 00 00
vkey(9223372036854775807)        = 30 ff ff ff ff ff ff ff ff
vkey("")                         = 40 00 00
vkey("ada")                      = 40 61 64 61 00 00
vkey("a\u0000b")                 = 40 61 00 ff 62 00 00
```

and a full index key, for the document key `u1` under the indexed value `36`:

```
30 80 00 00 00 00 00 00 24 75 31          (11 bytes)
```

If an index key would be longer than `MAX_INDEX_KEY = 128` bytes, the operation
that would create it fails with `error index-key-too-long` and changes nothing.
This can only happen with a long string field value: for a key of `K` bytes, a
string value of `S` UTF-8 bytes containing `Z` zero bytes needs `3 + S + Z + K`
bytes.

### 14.2 What an index contains

For every document `(key, doc)` in the store and every live index on `path`:
resolve `path` against `doc` (§6.4). If it is missing, or resolves to a list or
an object, there is **no** entry for this document in this index. Otherwise there
is exactly one entry, `vkey(value) ‖ key`. The slot's `entries` field is the
number of entries in the tree.

### 14.3 Index maintenance on a write

Every `put`, `update`, `unset` and `delete` keeps every live index exact. The
order of operations is fixed, because it determines page numbers:

**`put` / `update` / `unset`** on key `k`, old document `old` (absent for a
fresh key) and new document `new`:

1. Validate everything (§18.3). In particular compute every live index's new
   index key for `new`; if any exceeds 128 bytes, fail with
   `index-key-too-long` and change nothing.
2. **Primary tree first.** If `k` already exists: free its overflow chain in
   chain order (§9), then build the new cell — allocating the new overflow chain
   in chain order — and replace the leaf cell in place (§12.2), splitting if
   needed. If `k` is new: build the cell (allocating overflow) and insert it,
   splitting if needed, then `primary_count = primary_count + 1`.

   The cell, including its whole overflow chain, is built **before** the tree
   insert begins. So the overflow pages of a document are allocated before any
   page the insert itself allocates — before a new root leaf for an empty tree,
   and before any split sibling.
3. **Then the indexes, in slot order.** For each live index: let `o` be the old
   entry key (if `old` existed and was indexable at that path) and `w` the new
   entry key (if `new` is indexable there).
   - `o` and `w` both absent: nothing.
   - `o` absent, `w` present: insert `w`, `entries += 1`.
   - `o` present, `w` absent: delete `o`, `entries -= 1`.
   - both present and equal: nothing.
   - both present and different: delete `o`, then insert `w`; `entries`
     unchanged.

**`delete`** of key `k` with document `old`:

1. Read `old` (walking its overflow chain).
2. Free `old`'s overflow chain in chain order.
3. Remove the leaf cell from the primary tree (§12.4), handling underflow;
   `primary_count = primary_count - 1`.
4. For each live index in slot order: if `old` was indexable at that path,
   delete its entry and decrement `entries`.

Note the asymmetry — `put` touches the primary tree before the indexes and so
does `delete`, but `delete` frees the overflow chain **before** removing the
leaf cell, while `put` frees it before allocating the new one. Both orders are
observable in the free list, so follow them literally.

A worked illustration of that free-then-allocate order, because it surprises
people: against a fresh database, `put "a" <a 2005-byte document>` puts chunk 1
(1012 bytes) on page 2, chunk 2 (801 bytes) on page 3 and the root leaf on page
4. Replacing it with the **same** document frees the chain first — `free(2)`
then `free(3)`, leaving the list `3 → 2` — and then allocates the new chain
first chunk first, popping page 3 for chunk 1 and page 2 for chunk 2. The
document is unchanged but the chain now runs `3 → 2`, with the leaf cell's
`overflow` field pointing at page 3. `page_count` stays 4.

### 14.4 `create index <path>`

1. If a live slot already has this path text → `error index-exists`.
2. If `index_count == 16` → `error index-limit`.
3. Compute the index key of every document in the store, walking the primary
   tree **in key order**. If any would exceed 128 bytes →
   `error index-key-too-long`, nothing changes.
4. Take the lowest unused slot; set `live = 1`, the path text and its length,
   `root = 0`, `entries = 0`; `index_count += 1`.
5. Walk the primary tree in key order again and, for each indexable document,
   insert its entry into the new tree with the ordinary insert of §12.2,
   incrementing `entries`.

The insertion order in step 5 is **primary key order**, which is the order step 3
walked in; it is *not* index-key order, and the entries must not be sorted by
index key first. This matters: feeding the same set of entries to §12.2 in a
different order gives different split points and different page numbers, so an
implementation that pre-sorts produces a different `main.tdb`. Splits happen
exactly where the algorithm of §12.3 puts them for that insertion order.

The error checks happen before any page is allocated, so a failing
`create index` leaves no trace.

### 14.5 `drop index <path>`

1. If no live slot has this path text → `error index-missing`.
2. Free every page of that index's tree in **post-order page order** (§12.6). An
   empty index (`root == 0`) frees nothing.
3. Zero all 48 bytes of the slot; `index_count -= 1`.

The result reports how many pages were freed.

---

## 15. The write-ahead log

`main.twal` is a 32-byte header followed by a sequence of fixed-shape records.
It is append-only during a run; the only things that shorten it are recovery
(§16) and checkpointing (§15.6).

### 15.1 Log header

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `magic` — the ASCII bytes `TESSWAL1` (`54 45 53 53 57 41 4c 31`) |
| 8 | 2 | `format_version` — `1` |
| 10 | 2 | `page_size` — `1024` |
| 12 | 16 | reserved, **all zero** |
| 28 | 4 | `crc` — CRC-32 of bytes 0–27 |

Those four fields are constant, so the header is always exactly these 32 bytes:

```
00000000  54 45 53 53 57 41 4c 31 00 01 04 00 00 00 00 00
00000010  00 00 00 00 00 00 00 00 00 00 00 00 51 e7 21 53
```

An "empty log" is these 32 bytes and nothing more.

### 15.2 Record header

Every record starts with the same 24 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `type` — `1` page image, `2` commit |
| 1 | 3 | zero |
| 4 | 8 | `txn_id` — the `commit_counter` value this transaction takes on commit |
| 12 | 4 | `page_no` (type 1) or `frame_count` (type 2) |
| 16 | 4 | `payload_len` — `1024` for type 1, `0` for type 2 |
| 20 | 4 | `crc` — CRC-32 of this record's bytes 0–19 followed by its payload |

The payload follows immediately. A **page image record** is therefore
`24 + 1024 = 1048` bytes and carries one page's exact 1024 bytes; a **commit
record** is 24 bytes with no payload and its `frame_count` is the number of page
image records that belong to this transaction.

### 15.3 What a commit appends

A commit with `txn_id = t` and dirty pages `p1 < p2 < … < pk` appends

```
page image(t, p1) page image(t, p2) … page image(t, pk) commit(t, k)
```

in exactly that order — `k` records of 1048 bytes and one of 24, so
`1048*k + 24` bytes. `k ≥ 1` always, because a commit increments
`commit_counter` and so always rewrites page 1 (§13.4).

The very first commit against the fresh database of §21.1 (`put "a" 1`) appends
2120 bytes — the page 1 image, the page 2 image and the commit record — taking
the log from 32 to 2152 bytes. Their record headers are

```
page 1 image:  01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 01
               00 00 04 00 76 29 2e 36
page 2 image:  01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 02
               00 00 04 00 76 0d 60 f7
commit:        02 00 00 00 00 00 00 00 00 00 00 01 00 00 00 02
               00 00 00 00 a8 a0 aa 22
```

— type, three zero bytes, `txn_id = 1`, then `page_no` 1 and 2 for the images
and `frame_count = 2` for the commit, then `payload_len`, then the CRC.

### 15.4 Log size

The log's size in bytes is `32 + Σ (1048 per page image + 24 per commit
record)` over the records it currently holds. This is the number `stat` prints
as `wal` (§19) and the number compared against `WAL_LIMIT`.

### 15.5 Reading through the log

The engine does not re-read the log to serve reads; it keeps the **overlay**
(§13.1), the newest committed image of each page. A page image belonging to a
transaction that has no commit record is never in the overlay.

### 15.6 Checkpointing

A checkpoint copies the log into the main file and empties the log:

1. Let `O` be the overlay: page numbers mapped to their newest committed images.
   Let `n` be the number of entries in `O`. No transaction may be open (§13.5).
2. Let `PC` be `page_count` as seen through the overlay — that is, from `O`'s
   page 1 image if there is one, otherwise from the main file's page 1.
3. Set the length of `main.tdb` to exactly `PC * 1024` bytes. Any byte added
   beyond the previous end of file is `0x00`.
4. For each page number in `O`, **in ascending order**, write its 1024-byte
   image at offset `(p-1) * 1024`.
5. Empty `O`. Reset the log to the 32-byte header of §15.1 — so its size becomes
   32.
6. The result block reports `n` (§19).

Every page number in `O` is `≤ PC` (for images recovered from an input log, by
the guarantee at the end of §16.3). A checkpoint when `O` is empty is a no-op
that still rewrites the log header and reports `0`.

A checkpoint never changes the logical content of the database and never
allocates or frees a page.

### 15.7 Automatic checkpointing

After every commit (explicit or implicit), if the log's size is
`≥ WAL_LIMIT = 262144` bytes, a checkpoint runs immediately as the last step of
that commit. This is the only implicit checkpoint; in particular there is none
when the database is opened, none when a read-only command runs, and none at the
end of the script.

An automatic checkpoint is invisible in that command's own result block; it
shows up in the following `stat` (as `wal 32`) and of course in the output
files.

---

## 16. Opening a database and crash recovery

Opening happens once, before the first command, and in this order.

### 16.1 The main file

If the input directory has no `main.tdb`, or it is zero bytes long, the engine
starts from the fresh database of §7.3: a one-page file whose page 1 is as
specified there. Otherwise the file's bytes are used as they are.

### 16.2 The log header

If the input directory has no `main.twal`, the log starts empty: the 32-byte
header of §15.1, with an empty overlay.

If `main.twal` is present it is examined. The header is **valid** when all of
these hold:

- the file is at least 32 bytes long;
- bytes 0–7 are `TESSWAL1`;
- `format_version` is 1 and `page_size` is 1024;
- bytes 12–27 are all zero;
- the stored `crc` equals CRC-32 of bytes 0–27.

If the header is **not** valid, the whole log is discarded: nothing is replayed,
the overlay is empty, and the engine's log becomes a fresh 32-byte header.
(A zero-length `main.twal` falls in this case.)

### 16.3 Scanning the records

With a valid header, records are scanned from offset 32 forward. The scan keeps
an *open group*: a `txn_id` and the page images seen for it so far. It also
keeps `valid_end`, the offset just past the last commit record it accepted,
starting at 32.

At offset `off`, with `rem` bytes remaining in the file:

1. If `rem < 24`, **stop**.
2. Read the 24-byte record header. **Stop** unless all of:
   - `type` is 1 or 2;
   - bytes 1–3 are zero;
   - `payload_len` is 1024 when `type == 1`, and 0 when `type == 2`;
   - the field at offset 12 is at least 1 — `page_no ≥ 1` for a page image
     (page 0 does not exist) and `frame_count ≥ 1` for a commit record (§15.3);
   - `rem ≥ 24 + payload_len`;
   - the stored `crc` equals CRC-32 over bytes 0–19 of the record followed by its
     `payload_len` payload bytes.
3. If `type == 1`: if a group is open its `txn_id` must equal this record's
   `txn_id`, otherwise **stop**; if no group is open, open one with this
   `txn_id`. Append `(page_no, payload)` to the group. Advance
   `off += 24 + 1024`.
4. If `type == 2`: a group must be open, its `txn_id` must equal this record's
   `txn_id`, and the group's number of page images must equal `frame_count`;
   otherwise **stop**. Otherwise the transaction **commits**: merge its images
   into the overlay in the order they appeared (so a later image of the same page
   wins), close the group, advance `off += 24` and set `valid_end = off`.

No other validation is performed — `txn_id`s are not checked against the main
file's `commit_counter` and are not required to be contiguous. Records are
replayed strictly in file order.

The page **contents** are not validated either, and need not be: the test inputs
guarantee that, after every transaction the scan accepts, the database seen
through the overlay is a valid one — the newest page 1 image is a well-formed
header page, every page number in the overlay is at most that header's
`page_count`, and every page reachable from the header is a well-formed page of
the kind §7–§11 describe. (A log's later image of a page may follow an earlier,
meaningless image of the same page in the same transaction; only the newest
image counts.)

### 16.4 Trimming

When the scan stops, the engine's log becomes exactly bytes `0 … valid_end-1` of
the input log (which is just the header when `valid_end == 32`), and later
commits append at `valid_end`. Everything after `valid_end` — an incomplete
transaction, a half-written record, trailing garbage — is **gone** from the
output `main.twal`.

So for a log cut at an arbitrary byte offset: every transaction whose commit
record survived intact is applied and kept; everything after that commit record
is dropped. This holds whether the cut fell inside a record header, inside a
page payload, between two page images, or exactly at a record boundary.

### 16.5 After recovery

The engine's header fields are read through the overlay (§13.1), so they come
from the newest committed page 1 image if the log had one, and from the main
file otherwise. `main.tdb` is **not** modified by recovery — if the script issues
no checkpoint, the output `main.tdb` is a byte-for-byte copy of the input one.

---

## 17. Queries

### 17.1 Predicate grammar

```ebnf
pred   = disj ;
disj   = conj { "or" conj } ;
conj   = term { "and" term } ;
term   = "(" pred ")"
       | "not" "(" pred ")"
       | "exists" path
       | "missing" path
       | path cmpop value ;
cmpop  = "==" | "!=" | "<" | "<=" | ">" | ">=" ;
```

`and` binds tighter than `or`; both are left-associative.

Because a `WORD` can be a path segment as well as a keyword, the parser
disambiguates a `term` by its first one or two tokens, in this order:

1. `(` → a parenthesised predicate.
2. `WORD` spelled `not` whose **next token is `(`** → a negation.
3. `WORD` spelled `exists` whose **next token is a `WORD`** → an existence test.
4. `WORD` spelled `missing` whose **next token is a `WORD`** → a non-existence
   test.
5. `WORD` → a path, which must be followed by a `cmpop` and a value.
6. anything else → `error syntax`.

After a complete `term`, a following `WORD` spelled `and` or `or` is the
corresponding operator; any other `WORD` ends the predicate (so the command
parser can take `limit`). A field actually called `and`, `or`, `not`, `exists`
or `missing` is therefore reachable only in the first position of a term, which
is enough for every case in the tests.

### 17.2 Semantics

`exists path` is true when resolving `path` against the document (§6.4) yields a
value; `missing path` is its negation. `not(p)` is the negation of `p`.

`path cmpop value` is evaluated as follows. Let `x` be the result of resolving
`path`.

- If `path` is **missing**, every one of the six operators yields **false**.
  (So `not(a == 1)` is true for a document without an `a`, while `a != 1` is
  false.)
- `==` is true when `x` and `value` have the same type rank (§4) and are
  **deeply equal**.
- `!=` is the negation of `==` (for a present `x`): true when the ranks differ,
  or the ranks agree and the values are not deeply equal.
- `<`, `<=`, `>`, `>=` are **false** whenever the type ranks differ, and also
  false whenever either side is a list or an object. Otherwise:
  - `null` vs `null`: the two are equal, so `<` and `>` are false and `<=` and
    `>=` are true;
  - `bool`: `false < true`;
  - `int`: numeric order;
  - `string`: byte-wise order of the UTF-8 (§5.1).

Deep equality:

- `null`/`bool`/`int`: the obvious thing.
- `string`: identical UTF-8 bytes.
- `list`: same length and element-wise deeply equal, in order.
- `object`: the same set of field names and deeply equal values for each.

### 17.3 Plan selection

`find` reports its plan, so plan selection is observable and fully determined.

1. Flatten the predicate tree over `and` nodes from the root: repeatedly replace
   an `and` node by its two children until the top level is a list of
   **leaves**. (`or`, `not`, `exists`, `missing` and comparisons are leaves;
   parentheses do not survive parsing, so `(a==1 and b==2) and c==3` flattens to
   three leaves.)
2. A leaf is **usable** when all of:
   - it is a comparison `path cmpop value`;
   - `cmpop` is one of `==`, `<`, `<=`, `>`, `>=` (never `!=`);
   - `value` is `null`, a bool, an int or a string (never a list or object);
   - a live index exists whose path text equals this leaf's path text.
3. If no leaf is usable, the plan is **`scan`**.
4. Otherwise the plan is **`index <path>`** for the single best usable leaf,
   chosen by:
   1. a leaf with `==` beats a leaf with a range operator;
   2. then the smaller index path text, compared byte-wise;
   3. then the leaf that appears earliest in the line, left to right.

The chosen leaf also fixes the **candidate range** over that index. With
`V = vkey(value)`, and comparing index keys byte-wise (§5.1):

| Operator | Candidate entries |
|---|---|
| `==` | every entry whose index key has `V` as a prefix |
| `<` | every entry whose index key is `< V` |
| `<=` | every entry whose index key is `< V`, or has `V` as a prefix |
| `>` | every entry whose index key is `> V` and does not have `V` as a prefix |
| `>=` | every entry whose index key is `≥ V` |

These are *candidates*, not answers: they may include documents of a different
type rank (for a range operator the lower ranks all sort before the ints and
strings), and they are not filtered by the other leaves. Every document that
satisfies the whole predicate is in the candidate set, because a satisfied
comparison forces the field to exist with the same type rank as `value`, and
every such document has an entry in the index inside the stated range.

### 17.4 Evaluation

- **`scan` plan**: walk the primary tree in key order, read each document, keep
  the ones the predicate accepts.
- **`index <path>` plan**: walk the index tree in index-key order over the
  candidate range; for each entry, recover the document key (the bytes after the
  decoded `vkey`), read that document from the primary tree, and keep it if the
  predicate accepts it. A document has at most one entry per index, so no
  deduplication is needed.

In both cases the kept documents are then emitted in **ascending primary key
order**, and `limit n` keeps only the first `n` of them. The plan therefore never
changes the output other than the plan word itself.

---

## 18. Errors

A command either succeeds or fails with exactly one **error kind**. A failing
command changes nothing at all: no page, no header field, no log byte, no
transaction state. It never crashes the program and never changes the exit
status.

### 18.1 The kinds

| Kind | Raised when |
|---|---|
| `syntax` | the line does not lex or does not parse |
| `unknown-command` | the first token is a `WORD` that is not a command spelling |
| `bad-utf8` | a `\uXXXX` escape leaves an unpaired surrogate |
| `int-range` | an `INT` token's value does not fit in signed 64 bits |
| `dup-field` | an object literal names the same field twice |
| `depth` | a value nests deeper than `MAX_DEPTH = 32` |
| `bad-key` | a key argument is empty or longer than `MAX_KEY = 128` bytes |
| `bad-path` | a path has more than 8 segments, or its text exceeds 30 bytes |
| `not-found` | the key is not in the store |
| `no-field` | `unset`'s path is missing from the document |
| `not-object` | a path traverses a value that is not an object |
| `doc-too-large` | the serialised document exceeds `MAX_DOC = 65536` bytes |
| `index-key-too-long` | an index key would exceed `MAX_INDEX_KEY = 128` bytes |
| `index-exists` | `create index` on a path that already has an index |
| `index-missing` | `drop index` on a path that has no index |
| `index-limit` | `create index` with all 16 slots live |
| `txn-active` | `begin` or `checkpoint` while a transaction is open |
| `no-txn` | `commit` or `rollback` with no transaction open |

### 18.2 Stage order

1. **Lexing.** The whole line is tokenised. Any byte that cannot begin a token,
   any malformed token, an unterminated string literal, a bad escape, a bad
   `INT` shape → `syntax`. A line with no tokens → `syntax`.
2. **Command word.** If the first token is not a `WORD` → `syntax`. If it is a
   `WORD` that is not one of the fifteen command spellings →
   `unknown-command`.
3. **Parsing.** The rest of the line is parsed left to right. Each token's value
   is resolved as the parser consumes it, so the **first** problem in source
   order is the one reported: a structural mismatch or a leftover token →
   `syntax`; an unpaired surrogate → `bad-utf8`; an out-of-range integer →
   `int-range`; a repeated object field → `dup-field`; a literal nesting past
   depth 32 → `depth`; a key argument of the wrong length → `bad-key`; a path
   that is too long → `bad-path`.
4. **Execution.** The per-command order of §18.3.

A token left over after a complete command is never resolved: it is
`syntax` whatever it would have resolved to, so `get "a" "\ud800"` and
`put "a" 1 99999999999999999999` are both `syntax`.

So `frobnicate "\ud800"` is `unknown-command` (stage 2 precedes stage 3), while
`put "\ud800" 1` is `bad-utf8` and `put 1 "x"` is `syntax` (the parser wants a
string where the `INT` sits, and that comes before the string is resolved).

### 18.3 Per-command execution order

Each list is checked top to bottom; the first failing check is the error.

**`begin`** — `txn-active` if a transaction is open.

**`commit`**, **`rollback`** — `no-txn` if none is open.

**`checkpoint`** — `txn-active` if one is open.

**`stat`**, **`indexes`** — cannot fail.

**`put <key> <value>`**
1. the serialised document exceeds `MAX_DOC` → `doc-too-large`;
2. for each live index in slot order, the new index key exceeds 128 bytes →
   `index-key-too-long`;
3. otherwise perform §14.3.

In check 2 — and in check 5 of `update` below, and in step 3 of §14.4 — only a
document that is **indexable** at that path has an index key to measure: when
the path is missing from the new document, or resolves to a list or an object,
that index has no entry for it (§14.2) and contributes no check.

**`get <key>`**
1. the key is absent → `not-found`;
2. otherwise emit the document.

**`delete <key>`**
1. the key is absent → `not-found`;
2. otherwise perform §14.3.

**`update <key> <path> <value>`**
1. the key is absent → `not-found`;
2. walk the path: the document itself, or any value reached by a segment before
   the last, is present and not an object → `not-object`. A segment before the
   last that is **missing** creates a new empty object there (auto-vivification);
   the last segment is set to `value`, replacing any existing field;
3. the resulting document nests deeper than 32 → `depth`;
4. its serialised length exceeds `MAX_DOC` → `doc-too-large`;
5. for each live index in slot order, the new index key exceeds 128 bytes →
   `index-key-too-long`;
6. otherwise perform §14.3 with the new document.

**`unset <key> <path>`**
1. the key is absent → `not-found`;
2. walk the path from the document: at each segment, if the current value is not
   an object → `not-object`; if it is an object without that field → `no-field`.
   The first failure along the path decides;
3. otherwise remove that field (leaving an empty object behind if it was the
   only one) and perform §14.3 with the new document. This can never produce
   `doc-too-large` or `index-key-too-long`.

**`scan`**, **`find`** — cannot fail once parsed.

**`create index <path>`** — §14.4: `index-exists`, then `index-limit`, then
`index-key-too-long`.

**`drop index <path>`** — §14.5: `index-missing`.

---

## 19. `results.txt`

`results.txt` holds one **block** per line of `commands.txt`, in order, and
nothing else. Every line of the file, including the last, ends with a single LF.
There are no blank lines.

A block is a **status line** followed by zero or more **payload lines**:

```
[<k>] <status>
  <payload>
  <payload>
```

- `<k>` is the 1-based line number of the command, in decimal with no padding.
- The status line is `[`, `<k>`, `]`, one space, then the status text.
- Every payload line begins with exactly **two spaces**, then its content.

All integers printed anywhere in `results.txt` are decimal, with no sign, no
padding and no separators (`0`, `7`, `1024`).

### 19.1 Status texts

| Command | Status | Payload lines |
|---|---|---|
| `begin` | `ok begin` | none |
| `commit` | `ok commit <txn_id> frames <k>` | none |
| `rollback` | `ok rollback` | none |
| `checkpoint` | `ok checkpoint pages <n>` | none |
| `put` (new key) | `ok put created` | none |
| `put` (existing key) | `ok put replaced` | none |
| `get` | `ok get value` | one: the rendered document |
| `delete` | `ok delete removed` | none |
| `update` | `ok update updated` | none |
| `unset` | `ok unset updated` | none |
| `scan` | `ok scan <count>` | `<count>` lines |
| `find` | `ok find <count> plan <plan>` | `<count>` lines |
| `create index` | `ok create index <path> entries <n>` | none |
| `drop index` | `ok drop index <path> pages <n>` | none |
| `indexes` | `ok indexes <n>` | `<n>` lines |
| `stat` | `ok stat` | exactly 9 lines |
| any failure | `error <kind>` | none |

Details:

- `commit`: `<txn_id>` is the new `commit_counter`, `<k>` the number of page
  image records appended (§15.3), always at least 1.
- `checkpoint`: `<n>` is the number of pages copied into `main.tdb` (§15.6).
- `drop index`: `<n>` is the number of pages freed.
- `<plan>` is either the single word `scan` or `index ` followed by the index's
  path text.
- `<path>` is always the path *text* (segments joined by `.`), never the
  input spelling.

### 19.2 Payload lines

- `get`: one line, the rendered document (§4.4).
- `scan` without `keys`, and `find`: one line per result,
  `<rendered key>` then ` = ` (space, equals sign, space) then
  `<rendered document>`.
- `scan` with `keys`: one line per result, just `<rendered key>`.
- Keys are rendered as strings, with the escaping of §4.5 and the surrounding
  double quotes.
- `indexes`: one line per live index, in ascending slot order:
  `<slot> <path> root <root> entries <entries>`.
- `stat`: exactly these nine lines, in this order:

```
  pages <page_count>
  free <freelist_count>
  freehead <freelist_head>
  docs <primary_count>
  root <primary_root>
  height <height of the primary tree>
  commits <commit_counter>
  indexes <index_count>
  wal <log size in bytes>
```

  All nine come from the engine's current view, which inside a transaction
  includes that transaction's uncommitted changes (§13.5). `wal` is the size the
  log file would have right now (§15.4) — uncommitted pages are not counted.

### 19.3 A complete small `results.txt`

For the five-line script

```
put "b" 2
put "a" {name:"ada",age:36}
get "a"
scan
stat
```

run against a fresh database, `results.txt` is

```
[1] ok put created
[2] ok put created
[3] ok get value
  {"age":36,"name":"ada"}
[4] ok scan 2
  "a" = {"age":36,"name":"ada"}
  "b" = 2
[5] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 2
  indexes 0
  wal 4272
```

(`wal`: two commits, each with two page images — page 1 and the leaf page 2,
which the first command allocated and the second modified:
`32 + 2*(2*1048 + 24) = 4272`.)

---

## 20. Determinism checklist

Everything below is settled by this document. If an implementation's files
differ from the reference's, the cause is one of these.

1. **Page numbering** — pages are 1-based; page 1 is the header.
2. **Allocation** — pop the free list head if the list is non-empty, else extend
   the file by one page (§10). Never any other choice.
3. **Freeing** — push onto the head of the free list; chains and whole trees are
   freed in the orders of §9 and §12.6.
4. **Canonical pages** — pointer array in key order starting at byte 16, cells
   packed in key order ending at byte 1023, the gap zero-filled (§11.2). A page
   is re-encoded in full on every change.
5. **Split point** — the smallest `m ≥ 1` with `2 * P[m] ≥ T` (§12.3); the left
   half keeps the original page number; the new sibling is allocated at that
   moment; a new root is allocated after the sibling.
6. **Separator keys** — high keys; `sep` is the largest key left on the left
   page (leaf split) or the promoted cell's key (interior split); separators are
   never refreshed on deletion.
7. **Rebalancing** — borrow left, borrow right, merge left, merge right, in that
   order, with `MIN_FILL = 336` (§12.5); the left page survives a merge; a
   parent that a borrow overflows is split as in §12.3.
8. **Write order within a command** — primary tree before secondary indexes;
   indexes in slot order; the old overflow chain freed before the new one is
   allocated (§14.3).
9. **Index slots** — lowest unused slot; dropped slots zeroed; never compacted
   (§8).
10. **Commit** — `commit_counter` incremented first, page images in ascending
    page order, then the commit record (§13.4, §15.3).
11. **Checkpoint** — pages copied in ascending page order, file length set to
    `page_count * 1024`, log reset to its 32-byte header (§15.6); automatic only
    when the log reaches `WAL_LIMIT` after a commit (§15.7).
12. **Recovery** — committed transactions only, log trimmed to the end of the
    last accepted commit record (§16.4).
13. **Zero filling** — every byte this document calls reserved or padding is
    `0x00`, in every page and every record.
14. **Rollback at end of script** — an open transaction is discarded (§2.3).

---

## 21. Worked examples

Each example gives the input directory's contents and the exact `results.txt`,
plus whatever is interesting about the two binary outputs. Unless stated, the
input has no `main.tdb` and no `main.twal`, i.e. the script runs against the
fresh database of §7.3.

### 21.1 One document, then a checkpoint

`commands.txt`

```
put "a" 1
checkpoint
stat
```

`results.txt`

```
[1] ok put created
[2] ok checkpoint pages 2
[3] ok stat
  pages 2
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 1
  indexes 0
  wal 32
```

Walk-through. `put "a" 1` runs in an implicit transaction: the primary tree is
empty, so `allocate_page` extends the file and returns page 2, which becomes the
root leaf holding one cell. The commit bumps `commit_counter` to 1, so pages 1
and 2 are dirty and the log receives two page images and a commit record — 2120
bytes, taking it to 2152. The `checkpoint` then copies both pages into
`main.tdb` (ascending order, pages 1 then 2), sets the file length to
`2 * 1024`, and resets the log to its 32-byte header.

Output `main.tdb` is 2048 bytes: page 1 is exactly the header page shown in
§7.2, and page 2 is exactly the leaf page shown in §11.3. Output `main.twal` is
exactly the 32 bytes of §15.1.

### 21.2 Deleting everything, then reusing the freed page

`commands.txt`

```
put "k1" "x"
put "k2" "y"
delete "k1"
delete "k2"
stat
put "k3" "z"
stat
```

`results.txt`

```
[1] ok put created
[2] ok put created
[3] ok delete removed
[4] ok delete removed
[5] ok stat
  pages 2
  free 1
  freehead 2
  docs 0
  root 0
  height 0
  commits 4
  indexes 0
  wal 8512
[6] ok put created
[7] ok stat
  pages 2
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 5
  indexes 0
  wal 10632
```

Deleting `k2` empties the root leaf, so page 2 is freed and `primary_root`
becomes 0 (§12.4). The free list now holds one page, head 2. The next `put`
finds the tree empty, calls `allocate_page`, and pops page 2 straight back off
the free list — `page_count` stays at 2. Each of the five commits wrote two page
images, so the log is `32 + 5 * 2120 = 10632` bytes.

### 21.3 An overflow chain

`commands.txt`

```
put "big" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]
stat
get "big"
delete "big"
stat
```

The document serialises to `1 + 4 + 25*9 = 230` bytes, so 192 bytes stay in the
leaf cell and the remaining 38 go to one overflow page with `payload_len = 38`.
The overflow page is allocated **before** the insert (§14.3), so it is page 2
and the root leaf is page 3.

`results.txt`

```
[1] ok put created
[2] ok stat
  pages 3
  free 0
  freehead 0
  docs 1
  root 3
  height 1
  commits 1
  indexes 0
  wal 3200
[3] ok get value
  [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]
[4] ok delete removed
[5] ok stat
  pages 3
  free 2
  freehead 3
  docs 0
  root 0
  height 0
  commits 2
  indexes 0
  wal 6368
```

The delete frees the overflow chain first (page 2, pushing it onto the free
list), then removes the leaf cell, which empties the root leaf and frees page 3
on top of it — hence `freehead 3` and `free 2`. Each commit dirtied pages 1, 2
and 3, so each appended `3 * 1048 + 24 = 3168` bytes.

### 21.4 Rollback and commit

`commands.txt`

```
begin
put "a" 1
put "b" 2
stat
rollback
stat
begin
put "a" 1
commit
stat
```

`results.txt`

```
[1] ok begin
[2] ok put created
[3] ok put created
[4] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 0
  indexes 0
  wal 32
[5] ok rollback
[6] ok stat
  pages 1
  free 0
  freehead 0
  docs 0
  root 0
  height 0
  commits 0
  indexes 0
  wal 32
[7] ok begin
[8] ok put created
[9] ok commit 1 frames 2
[10] ok stat
  pages 2
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 1
  indexes 0
  wal 2152
```

Inside the first transaction `stat` reports the uncommitted state — two
documents, `page_count` 2 — while `wal` is still 32 because nothing has been
committed. The rollback discards page 1 along with everything else, so
`page_count` is 1 again. No checkpoint ever runs, so the output `main.tdb` is
the 1024-byte fresh database of §7.3 while all the data lives in the 2152-byte
`main.twal`.

### 21.5 Errors

`commands.txt`

```
put "a" 1
put "a" 2
get "zz"
delete "zz"
frobnicate
put "a"
put "a" 007
put "a" 9223372036854775808
put "a" {x:1,x:2}
put "\ud800" 1
put "" 1
commit
rollback
begin
begin
checkpoint
```

`results.txt`

```
[1] ok put created
[2] ok put replaced
[3] error not-found
[4] error not-found
[5] error unknown-command
[6] error syntax
[7] error syntax
[8] error int-range
[9] error dup-field
[10] error bad-utf8
[11] error bad-key
[12] error no-txn
[13] error no-txn
[14] ok begin
[15] error txn-active
[16] error txn-active
```

Line 6 is missing its value; line 7's `007` is not a valid `INT` token; line 8's
integer is one past the signed 64-bit maximum; line 10's escape is an unpaired
high surrogate; line 11's key is empty. The transaction opened on line 14 is
still open at end of input and is rolled back silently (§2.3), so only the two
commits from lines 1 and 2 reach the log.

### 21.6 A secondary index and `find`

`commands.txt`

```
put "u1" {name:"ada",age:36}
put "u2" {name:"bob",age:29}
put "u3" {name:"cy",age:36}
create index age
indexes
find age == 36
find age > 30
find age == 36 and name == "cy"
find not(age == 36)
stat
```

`results.txt`

```
[1] ok put created
[2] ok put created
[3] ok put created
[4] ok create index age entries 3
[5] ok indexes 1
  0 age root 3 entries 3
[6] ok find 2 plan index age
  "u1" = {"age":36,"name":"ada"}
  "u3" = {"age":36,"name":"cy"}
[7] ok find 2 plan index age
  "u1" = {"age":36,"name":"ada"}
  "u3" = {"age":36,"name":"cy"}
[8] ok find 1 plan index age
  "u3" = {"age":36,"name":"cy"}
[9] ok find 1 plan scan
  "u2" = {"age":29,"name":"bob"}
[10] ok stat
  pages 3
  free 0
  freehead 0
  docs 3
  root 2
  height 1
  commits 4
  indexes 1
  wal 8512
```

The index tree holds three entries, in index-key order
`vkey(29)‖"u2"`, `vkey(36)‖"u1"`, `vkey(36)‖"u3"`; the hex in §11.5 is that same
index leaf page holding just the first two of them. Line 6 seeks to the first key with the prefix `vkey(36)` and
walks forward over two entries. Line 7 uses `vkey(30)` as its lower bound, so
`u2`'s entry falls below the range and only `u1` and `u3` are candidates; both
satisfy `age > 30`. Line 8 uses the same `==` candidates and then rejects `u1`
because of the second leaf, which has no index. Line 9's whole predicate is a
single `not` leaf, which is never usable, so the plan is `scan`; `u2` matches
because `age == 36` is false for it.

`create index` dirtied only pages 1 and 3 — the primary tree was read, not
written — so all four commits wrote two page images each.

### 21.7 Scan ranges

`commands.txt`

```
put "a" 1
put "b" 2
put "c" 3
put "d" 4
scan
scan from "b"
scan to "c"
scan from "b" to "d"
scan limit 2
scan reverse limit 2
scan keys reverse
scan from "d" to "b"
```

`results.txt`

```
[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok scan 4
  "a" = 1
  "b" = 2
  "c" = 3
  "d" = 4
[6] ok scan 3
  "b" = 2
  "c" = 3
  "d" = 4
[7] ok scan 2
  "a" = 1
  "b" = 2
[8] ok scan 2
  "b" = 2
  "c" = 3
[9] ok scan 2
  "a" = 1
  "b" = 2
[10] ok scan 2
  "d" = 4
  "c" = 3
[11] ok scan 4
  "d"
  "c"
  "b"
  "a"
[12] ok scan 0
```

`to` is exclusive, so line 7 stops before `"c"` and line 8 yields `"b"` and
`"c"`. Line 10 orders first and limits second, so it returns the two greatest
keys, descending. Line 12's bounds are empty.

### 21.8 `update` and `unset`

`commands.txt`

```
put "u1" {name:"ada"}
update "u1" age 36
update "u1" addr.city "oslo"
get "u1"
unset "u1" addr.city
get "u1"
unset "u1" addr.zip
unset "u1" name.first
update "u2" age 1
```

`results.txt`

```
[1] ok put created
[2] ok update updated
[3] ok update updated
[4] ok get value
  {"addr":{"city":"oslo"},"age":36,"name":"ada"}
[5] ok unset updated
[6] ok get value
  {"addr":{},"age":36,"name":"ada"}
[7] error no-field
[8] error not-object
[9] error not-found
```

Line 3 auto-vivifies `addr` as an empty object before setting `city`. Line 5
leaves `addr` behind as an empty object. Line 7's `addr` is an object but has no
`zip`. Line 8's `name` is a string, so the second segment cannot be traversed.

### 21.9 Checkpoint and `drop index`

`commands.txt`

```
put "u1" {age:1}
create index age
stat
checkpoint
stat
drop index age
stat
drop index age
```

`results.txt`

```
[1] ok put created
[2] ok create index age entries 1
[3] ok stat
  pages 3
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 2
  indexes 1
  wal 4272
[4] ok checkpoint pages 3
[5] ok stat
  pages 3
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 2
  indexes 1
  wal 32
[6] ok drop index age pages 1
[7] ok stat
  pages 3
  free 1
  freehead 3
  docs 1
  root 2
  height 1
  commits 3
  indexes 0
  wal 2152
[8] error index-missing
```

The checkpoint copies pages 1, 2 and 3 into a 3072-byte `main.tdb` and empties
the log. `drop index` then frees the index's single page (page 3) and zeroes
directory slot 0, which dirties pages 1 and 3 — so the output `main.tdb` still
shows the index while `main.twal` holds the newer state.

### 21.10 Recovery from a log truncated mid-record

The input directory holds all three entries.

`main.tdb` is the 1024-byte fresh database of §7.3.

`main.twal` is 3000 bytes: the first 3000 bytes of the log that the script
`put "a" 1` / `put "b" 2` would have produced against that fresh database. That
full log is 4272 bytes — transaction 1 occupies bytes 32–2151 (two page images
and a commit record) and transaction 2 occupies bytes 2152–4271. The cut at 3000
falls inside transaction 2's first page image, which runs from 2152 to 3199.

`commands.txt`

```
scan
stat
put "c" 3
stat
```

`results.txt`

```
[1] ok scan 1
  "a" = 1
[2] ok stat
  pages 2
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 1
  indexes 0
  wal 2152
[3] ok put created
[4] ok stat
  pages 2
  free 0
  freehead 0
  docs 2
  root 2
  height 1
  commits 2
  indexes 0
  wal 4272
```

The scan of §16.3 accepts transaction 1's two page images and its commit record,
setting `valid_end = 2152`. It then reads the next record header at 2152, finds
a well-formed page image header claiming a 1024-byte payload, and discovers that
only 824 payload bytes remain — so it stops. Transaction 2 is discarded
entirely, including the `"b"` document, and the log is trimmed to 2152 bytes.

`put "c" 3` then appends a new transaction with `txn_id = 2` at offset 2152. The
output `main.twal` is 4272 bytes long but is **not** the same 4272 bytes as the
untruncated log: its second transaction stores `"c"`, not `"b"`. The output
`main.tdb` is byte-for-byte the input `main.tdb`, because no checkpoint ran.

### 21.11 A log with a damaged header

The input directory holds `main.tdb` — the 2048-byte database produced by
§21.1 — and a `main.twal` of ten arbitrary bytes.

`commands.txt`

```
scan
stat
```

`results.txt`

```
[1] ok scan 1
  "a" = 1
[2] ok stat
  pages 2
  free 0
  freehead 0
  docs 1
  root 2
  height 1
  commits 1
  indexes 0
  wal 32
```

The log is shorter than 32 bytes, so its header is invalid and the whole log is
discarded (§16.2). The output `main.tdb` is the input file unchanged; the output
`main.twal` is the 32-byte header of §15.1. The same would happen for a 10
000-byte `main.twal` whose magic or header CRC was wrong.

### 21.12 A split, a borrow and a merge

Every document here is the 20-element list `[1,…,20]`, which serialises to
`1 + 4 + 20*9 = 185` bytes — inline, no overflow. With a 2-byte key each primary
leaf cell costs `2 + 12 + 2 + 185 = 201` bytes, so five cells fit on a page
(1005 ≤ 1008) and six do not (1206 > 1008).

`commands.txt`

```
put "k1" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k2" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k3" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k4" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k5" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k6" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
stat
scan keys
delete "k1"
delete "k2"
delete "k3"
stat
scan keys
```

`results.txt`

```
[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok put created
[6] ok put created
[7] ok stat
  pages 4
  free 0
  freehead 0
  docs 6
  root 4
  height 2
  commits 6
  indexes 0
  wal 14848
[8] ok scan 6
  "k1"
  "k2"
  "k3"
  "k4"
  "k5"
  "k6"
[9] ok delete removed
[10] ok delete removed
[11] ok delete removed
[12] ok stat
  pages 4
  free 2
  freehead 4
  docs 3
  root 2
  height 1
  commits 9
  indexes 0
  wal 25400
[13] ok scan 3
  "k4"
  "k5"
  "k6"
```

Walk-through:

- Commands 1–5 fill the root leaf, page 2, to `5 * 201 = 1005` bytes.
- Command 6 brings it to 1206, which overflows. With all six costs equal to 201
  and `T = 1206`, the split point is the smallest `m` with `402m ≥ 1206`, so
  `m = 3`: cells `k1 k2 k3` stay on page 2 and `k4 k5 k6` move to the newly
  allocated page 3, with `link(2) = 3`. The separator is `k3`, the largest key
  left behind. Page 2 was the root, so page 4 is allocated **after** page 3 as
  the new root, holding the single cell `("k3", 2)` with `link = 3`. This commit
  dirties pages 1, 2, 3 and 4, so it writes four page images.
- Command 9 removes `k1` from page 2, leaving `402 ≥ MIN_FILL`. Nothing else
  happens.
- Command 10 removes `k2`, leaving page 2 at 201 — an underflow. Page 2 is child
  0 of the root, so it has no left sibling; its right sibling is the root's
  `link`, page 3, at 603, which can give up its first cell and still hold
  `402 ≥ 336`. So **borrow from the right** applies: `k4` moves to the end of
  page 2 and the root's separator becomes `k4`. Pages 1, 2, 3 and 4 are written;
  no page is allocated or freed.
- Command 11 removes `k3`, leaving page 2 at 201 again. Page 3 is now at 402 and
  cannot lend (402 − 201 = 201 < 336); there is no left sibling; so
  **merge with the right** applies. Page 2 absorbs `k5` and `k6`, takes over
  `link(3) = 0`, and page 3 is freed. The root loses its only cell and its
  `link` is repointed to page 2; being a zero-cell root it is then collapsed:
  `primary_root` becomes 2 and page 4 is freed. The free list is therefore
  `4 → 3`, head 4.
- The log holds nine commits with 2, 2, 2, 2, 2, 4, 2, 4 and 4 page images:
  `32 + 5*2120 + 4216 + 2120 + 2*4216 = 25400`.

### 21.13 A page left thin by a replace, and a borrow that does not fill it

This example exists because `MIN_FILL` is a deletion threshold and nothing more
(§12.5). Documents are again the 20-element list of §21.12, 185 bytes, 201 bytes
of cost per cell.

`commands.txt`

```
put "k1" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k2" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k3" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k4" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k5" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k6" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
put "k1" 1
put "k2" 2
stat
delete "k3"
stat
scan keys
```

`results.txt`

```
[1] ok put created
[2] ok put created
[3] ok put created
[4] ok put created
[5] ok put created
[6] ok put created
[7] ok put replaced
[8] ok put replaced
[9] ok stat
  pages 4
  free 0
  freehead 0
  docs 6
  root 4
  height 2
  commits 8
  indexes 0
  wal 19088
[10] ok delete removed
[11] ok stat
  pages 4
  free 0
  freehead 0
  docs 5
  root 4
  height 2
  commits 9
  indexes 0
  wal 23304
[12] ok scan 5
  "k1"
  "k2"
  "k4"
  "k5"
  "k6"
```

Walk-through:

- Commands 1–6 build the tree of §21.12: page 2 holds `k1 k2 k3` at 603, page 3
  holds `k4 k5 k6` at 603, page 4 is the root with the single separator `k3`.
- Command 7 replaces `k1`'s document with the 9-byte document `1`, so its cell
  costs `2 + 12 + 2 + 9 = 25` and page 2 drops to 427. Command 8 does the same
  to `k2` and page 2 drops to **251, below `MIN_FILL`** — and nothing happens.
  No borrow, no merge, no page freed, no page allocated: `stat` still reports
  4 pages, no free pages, root 4 and height 2. Each of these two commits wrote
  two page images, pages 1 and 2.
- Command 10 deletes `k3`, leaving page 2 at 50. *That* is an underflow. Page 2
  is child 0 of the root and has no left sibling; its right sibling is page 3 at
  603, which can spare its first cell (`603 − 201 = 402 ≥ 336`), so
  **borrow from the right** applies. `k4` moves to the end of page 2 and the
  root's separator becomes `k4`. Page 2 now sits at 251 — still below
  `MIN_FILL`, and the repair stops anyway, because a borrow leaves the parent's
  cell count untouched. Pages 1, 2, 3 and 4 are written; nothing is allocated or
  freed.
- The log holds nine commits with 2, 2, 2, 2, 2, 4, 2, 2 and 4 page images:
  `32 + 5*2120 + 4216 + 2*2120 + 4216 = 23304`.

---

## 22. What the tests look like

The public tests in `tests/` are small, hand-checkable cases of the kind in §21.
The hidden suite is several hundred cases and covers, among other things:

- every error kind, and the precedence rules of §18.2 and §18.3;
- leaf and interior splits at every arity, including splits that cascade several
  levels and grow the tree's height;
- every branch of §12.5 — borrow left, borrow right, merge left, merge right —
  on both leaves and interior pages, including root collapse;
- overflow chains of 1 to 65 pages (the longest a `MAX_DOC` document needs),
  replaced in place, shrunk, grown and freed;
- free-list reuse patterns, including a page freed and reallocated inside one
  transaction;
- all sixteen index slots, index maintenance under `put`, `update`, `unset` and
  `delete`, index keys at exactly 128 bytes and one byte over;
- `find` over every operator and both plans, with ties in plan selection;
- explicit transactions committed and rolled back, interleaved with implicit
  ones, and a transaction left open at end of input;
- automatic checkpointing triggered by `WAL_LIMIT`, and explicit checkpoints
  with an empty log;
- recovery from logs cut at many offsets — every record boundary, inside record
  headers, inside page payloads, inside and just after commit records — and from
  logs with a bad magic, a bad version, a bad CRC and trailing garbage;
- random workloads of up to about 20 000 commands over keys, documents and
  indexes, where the only check that matters is that all three output files
  match the reference byte for byte.

There are no external data files: everything an implementation needs is in the
input directory and in this document.
