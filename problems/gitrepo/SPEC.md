# gitrepo — Git repository reader

Read a real git repository straight off disk and answer a list of queries
about it. The object database, the compression and the hash are all part of
the problem.

Read the repository yourself: don't invoke `git`, and don't use a git library,
a zlib/DEFLATE decompressor or a SHA-1 routine from a library, the standard
library or the language. Everything else the standard library offers (file I/O,
containers, sorting) is fine.

This document is self-contained. Where it decides something that git's own
documentation leaves open, this document wins; every expected output in
`tests/` was produced by a reference implementation of this document and
then checked against the git command line, so the two agree everywhere.

## Expected size and shape

A complete implementation is roughly 1200–2000 lines in a systems language.
The natural decomposition is:

1. **SHA-1** (~60 lines) — FIPS 180-4, used to validate objects.
2. **Inflate** (~200 lines) — RFC 1951 DEFLATE plus the two-byte RFC 1950
   zlib wrapper. The sibling problem `inflate` (`../inflate/SPEC.md`,
   i.e. `problems/inflate/SPEC.md`) specifies exactly this decoder in full
   detail and may be used as the reference for this part; only its decoder is
   needed here, not its stdin/stdout contract. Every stream in the tests is
   produced by zlib itself, so dynamic Huffman blocks dominate and stored
   blocks are rare but do occur.
3. **Object store** (~350 lines) — loose objects, packfile `.idx` v2 lookup,
   packfile object headers, `OFS_DELTA` / `REF_DELTA` reconstruction.
4. **Object parsing** (~150 lines) — commits, trees and tags.
5. **Refs and revision syntax** (~200 lines) — `HEAD`, loose refs,
   `packed-refs`, `^`, `~`, `^{...}`, abbreviated object ids.
6. **Commands** (~300 lines) — the six queries below.

## I/O contract

The program is run as

```
<program> <input path> <output dir>
```

with the current directory set to `problems/gitrepo/`. Nothing is read from
standard input and nothing outside `<output dir>` may be written. Anything
printed on stdout or stderr is ignored. The exit status must be 0.

`<input path>` is a directory holding exactly two entries:

- `repo/` — a git object database: the contents of a `.git` directory, or
  equivalently a bare repository.
- `commands.txt` — the queries, UTF-8, one per line, LF line endings. The
  final line may or may not end with a newline. There are no blank lines and
  no comments. There are at most 9999 commands.

For the command on line *k* (1-based) the program writes
`<output dir>/NNN.out`, where `NNN` is *k* in decimal, zero-padded to at
least three digits (`001`, `002`, … `999`, `1000`, …). Exactly one file per command is
written and no other files are created.

A command line is split into tokens on single space characters (U+0020).
Two adjacent spaces therefore produce an empty token, and a trailing space
produces an empty final token; both make the command invalid. So
`ls-tree main ` fails rather than listing the root tree, and `rev-parse  HEAD`
fails rather than resolving `HEAD`. No other whitespace is special.

### Failure

Every command either produces its answer or *fails*. A command that fails
produces the file content

```
error
```

(five bytes and a newline) — never a crash, never a nonzero exit status, and
never a partial answer. The reasons a command fails are listed with each
command; anything the program cannot carry out — an unknown command, the
wrong number of arguments, an unresolvable revision, a missing or damaged
object — is a failure.

## What `repo/` contains

Only these paths are read:

```
repo/HEAD
repo/refs/**
repo/packed-refs
repo/objects/<xx>/<38 hex digits>          loose objects
repo/objects/pack/<name>.idx               pack index, version 2
repo/objects/pack/<name>.pack              packfile, version 2
```

Everything else that may be present (`config`, `objects/info/`,
`commit-graph`, `multi-pack-index`, `index`, `logs/`) must be ignored. The
tests contain no alternate object stores, no shallow clones, no SHA-256
repositories, no pack index version 1 and no packfile version other than 2.

Byte strings in a repository (ref names, path names, author names, commit
messages) are not guaranteed to be valid UTF-8 and must be carried through
unchanged. All test corpora happen to be UTF-8, but an implementation that
treats them as opaque bytes is the intended one.

## Hashing

An object's **id** is the SHA-1 (FIPS 180-4) of its *stored form*

```
<type> SP <size> NUL <payload>
```

where `<type>` is one of `blob`, `tree`, `commit`, `tag`, `<size>` is the
length of `<payload>` in bytes written in decimal with no leading zeros, `SP`
is a space and `NUL` is a zero byte. Ids are written as 40 lowercase
hexadecimal digits.

Example: the blob holding `one file\n` (9 bytes) has stored form
`blob 9\0one file\n` and id `b7814cae2e925fe74c6cd5816462fff515ccb256`.

## Decompression

Every stored object is compressed with the zlib format (RFC 1950): a two-byte
header, a raw DEFLATE stream (RFC 1951), then a four-byte Adler-32 checksum.

The header bytes `CMF FLG` must satisfy: `CMF & 0x0f == 8` (deflate),
`(CMF * 256 + FLG) % 31 == 0`, and `FLG & 0x20 == 0` (no preset dictionary).
Otherwise the object is damaged.

The Adler-32 trailer **may be ignored**. Where a packfile stores several
objects back to back, the end of a stream is found by decoding it, not by
knowing its compressed length: the DEFLATE stream ends at the end-of-block
symbol of its final block, and any bytes after that belong to the next
object.

One object in the test corpus has a damaged DEFLATE stream. Decoders that
verify the Adler-32 reject it there; decoders that do not verify it decode a
deterministic sequence of wrong bytes which then fails the object header
check below. Either way the answer is `error`.

## Loose objects

The object with id `H` may be stored at `repo/objects/H[0:2]/H[2:40]`. The
whole file is one zlib stream whose plaintext is the object's stored form. It
is damaged, and the containing command fails, if the plaintext does not begin
with one of the four type names followed by a space, a decimal size and a NUL
byte, or if the byte count after the NUL differs from that size.

A loose object is preferred over a packed copy of the same id.

## Packfiles

`repo/objects/pack/<name>.pack` is used only together with
`repo/objects/pack/<name>.idx`; a `.idx` with no matching `.pack`, or a
`.pack` with no matching `.idx`, is ignored entirely.

All multi-byte integers in the index and the pack header are big-endian.

### Index, version 2

```
offset  size          contents
0       4             \xff t O c
4       4             2                        (version)
8       1024          fanout[0..255]           cumulative counts
1032    20 * N        object ids, ascending
...     4  * N        CRC-32 of each packed object
...     4  * N        offsets
...     8  * M        64-bit offsets
...     20            SHA-1 of the packfile
...     20            SHA-1 of the index itself
```

`N` is `fanout[255]`. `fanout[b]` is the number of object ids whose first
byte is less than or equal to `b`, so the ids beginning with byte `b` occupy
positions `fanout[b-1] .. fanout[b]-1` (`0 .. fanout[0]-1` for `b == 0`) of
the sorted id table; a binary search inside that range finds an id. The
`i`-th entry of the offset table gives the position of object `i` in the
packfile: if its high bit is clear the remaining 31 bits are the offset; if
it is set, the remaining 31 bits index the table of 64-bit offsets. (The test
packs are all far smaller than 2 GiB, so the 64-bit table is empty.)

### Packfile

```
offset  size   contents
0       4      P A C K
4       4      2                      (version)
8       4      number of objects
12      ...    the objects
end     20     SHA-1 of everything before it
```

An object starts with a variable-length header. The first byte holds a
continuation bit (0x80), a three-bit type in bits 4–6, and the low four bits
of the size. Each further byte while the continuation bit is set contributes
seven more size bits, least significant group first. The size is the length
of the object after decompression (for a delta, the length of the delta
stream); an implementation does not need it, because the compressed stream
is self-terminating, but it must skip the header bytes correctly.

| type | meaning |
|---|---|
| 1 | `commit` |
| 2 | `tree` |
| 3 | `blob` |
| 4 | `tag` |
| 6 | `OFS_DELTA` |
| 7 | `REF_DELTA` |
| 0, 5 | invalid |

For type 6 the header is followed by a base offset, encoded as a different
variable-length integer: read the first byte into `v = b & 0x7f`; while the
byte's high bit is set, read the next byte `c` and set
`v = ((v + 1) << 7) | (c & 0x7f)`. The base object starts at
`this object's offset - v`, which is always inside the same packfile and
always before this object.

For type 7 the header is followed by the base object's 20-byte id. The base
may live anywhere in the repository: in this pack, in another pack, or loose.

After the base reference comes the zlib stream. For types 1–4 it decompresses
to the object payload. For types 6 and 7 it decompresses to a **delta**,
applied to the base; the reconstructed object has the base's type. Delta
chains may nest (a delta whose base is itself a delta) to any depth the tests
contain.

### Delta format

A delta begins with two sizes, each a variable-length integer read as
`value |= (byte & 0x7f) << shift` with `shift` increasing by 7 per byte and
the high bit marking continuation: the expected size of the base, then the
size of the result. Then come instructions until the delta is exhausted:

- A byte with the high bit **set** is a *copy*. Bits 0–3 select which of four
  offset bytes follow (least significant first), bits 4–6 which of three size
  bytes follow, in that order; absent bytes are zero. A size of 0 means
  0x10000. Append `size` bytes of the base starting at `offset`.
- A byte `n` with the high bit **clear** and `n != 0` is an *insert*: append
  the next `n` bytes of the delta.
- The byte `0x00` is invalid.

A copy reaching past the end of the base, or a result whose length differs
from the declared result size, makes the object damaged.

## Refs

`repo/HEAD` and the files under `repo/refs/` each hold either a 40-digit
lowercase object id or the text `ref: <name>` naming another ref, in both
cases followed by optional trailing whitespace. A symbolic ref is followed
recursively, at most 5 times.

`repo/packed-refs`, when present, is a text file of LF-terminated lines.
Lines starting with `#` are headers and lines starting with `^` are peeled
values; both are ignored here. Every other line is `<40 hex> SP <ref name>`.

A ref name resolves to the loose file `repo/<name>` when that file exists,
and otherwise to the `packed-refs` entry for `<name>`. Only `HEAD` and names
beginning with `refs/` are looked for on disk — no other file in the
repository is a ref, so `rev-parse config` fails even though `repo/config`
exists. Names containing an empty component, `.` or `..` never resolve.

The object id a ref holds is taken at face value: a ref pointing at an object
that is not in the database still resolves. Step 4 of the revision syntax
below is the only place that checks an object is present.

## Revision syntax

A `<rev>` is resolved as follows, which is exactly git's rule.

1. If it ends with `}`, find the last occurrence of `^{` in it. If that
   occurrence is not at position 0, split there: resolve the part before it,
   then apply the *peel* named between the braces.
   - `^{}` — while the object is a tag object, replace it by the object its
     `object` header names. Fails if there is no such object.
   - `^{commit}`, `^{tree}`, `^{blob}`, `^{tag}` — repeatedly: stop when the
     object has the wanted type; if it is a tag, take its target; if it is a
     commit, take its tree; otherwise fail.
   - `^{object}` — no change, but the object must be *present* in the sense
     of rule 4 below: a loose file or an entry in a pack index. Its content
     is not read, so an object that is present but damaged still resolves.
   - Anything else between the braces fails.
2. Otherwise, scan backwards over a possibly empty run of decimal digits. If
   the character before that run is `^` or `~` and is not the first character
   of the string, split there. Let `n` be the number, or 1 when the run is
   empty. Resolve the part before the operator and peel it to a commit as
   `^{commit}` does.
   - `^0` and `~0` — the commit itself.
   - `^n` for `n >= 1` — the commit's `n`-th parent, in the order the
     `parent` headers appear. Fails when there are fewer than `n` parents.
   - `~n` for `n >= 1` — follow the first parent `n` times. Fails when a
     commit on the way has no parent.
3. Otherwise the string is a name. Try it against these six patterns in
   order, using the first that resolves to an object id:
   `<name>`, `refs/<name>`, `refs/tags/<name>`, `refs/heads/<name>`,
   `refs/remotes/<name>`, `refs/remotes/<name>/HEAD`.
   (`HEAD` resolves through the first pattern.)
4. Otherwise, if the string is 4 to 40 hexadecimal digits in either case, it
   is an object id, lowercased. A 40-digit id must name an object that is
   present in the repository. A shorter one is an abbreviation: it must be a
   prefix of the id of exactly one object in the repository — zero matches or
   more than one match is a failure.
5. Otherwise the revision fails.

Resolving a revision only locates an object; it does not verify the object's
content. Only `cat-file` does that.

## Object formats

### Tree

A tree's payload is a sequence of entries with no separators:

```
<mode> SP <name> NUL <20-byte id>
```

`<mode>` is octal without a leading zero, `<name>` is a non-empty byte string
without `/` or NUL. Entries are stored in git's canonical order and are
emitted in stored order; an implementation never has to sort them.

| stored mode | printed mode | type |
|---|---|---|
| `40000` | `040000` | `tree` |
| `100644` | `100644` | `blob` |
| `100755` | `100755` | `blob` |
| `120000` | `120000` | `blob` (a symlink; the payload is the target) |
| `160000` | `160000` | `commit` (a submodule; the object is usually absent) |

The *object type* of an entry is decided by the high bits of its mode:
`mode & 0170000` equal to `0040000` is a tree, `0160000` is a commit,
everything else is a blob.

### Commit

A commit's payload is a header block, then a single empty line, then the
message. A header line that begins with a space continues the previous header
(this is how `gpgsig` carries a multi-line signature), so it can never be
mistaken for a new header. The headers that matter are:

```
tree <40 hex>
parent <40 hex>              zero or more, in order
author <name> <<email>> <seconds> <timezone>
committer <name> <<email>> <seconds> <timezone>
```

If a header appears more than once, the last occurrence wins (`parent` being
the exception: every occurrence counts). The message is everything after the
first empty line, including its terminating newline, and may be empty when
there is no empty line at all.

From an ident line (`author` or `committer`), take:

- the **name**: everything before the first `<`, with trailing whitespace
  removed;
- the **timestamp**: after the first `>` that follows that `<`, skip spaces,
  then skip an optional `+` or `-` sign and read the run of decimal digits
  that follows as a non-negative integer. Zero when the line has no such
  field. (A signed timestamp is rejected by `git fsck` and none of the test
  repositories contains one, so the sign is simply ignored here.)

The **subject** of a commit is computed from the message like this:

1. Split the message into lines on LF.
2. Strip trailing whitespace (space, tab, CR, LF, VT, FF) from each line.
3. Skip lines that are empty after stripping.
4. Take lines until the next line that is empty after stripping, and join
   them with a single space.

So a message `"\n\nFix the thing   \nand the other\n\nbody\n"` has subject
`Fix the thing and the other`, and a message with no non-blank line has the
empty subject.

### Tag

A tag object has the same header/message shape as a commit, with headers
`object`, `type`, `tag` and `tagger`. Only `object` is used here.

## Path quoting

`ls-tree` and `diff` print names with git's default quoting. A name is
printed as-is when every byte is in `0x20..0x7e` and is neither `"` (0x22)
nor `\` (0x5c). Otherwise it is wrapped in double quotes and each byte is
written as

| byte | output |
|---|---|
| 0x07 0x08 0x09 0x0a 0x0b 0x0c 0x0d | `\a` `\b` `\t` `\n` `\v` `\f` `\r` |
| `"` | `\"` |
| `\` | `\\` |
| below 0x20, or 0x7f and above | `\` and three octal digits |
| anything else | the byte itself |

For example the UTF-8 name `café.txt` prints as `"caf\303\251.txt"`, and the
name `quote"and\slash.txt` prints as `"quote\"and\\slash.txt"`.

## Commands

### `log <rev> [<n>]`

Resolves `<rev>`, peels it to a commit as `^{commit}` does, and walks history
from there. `<n>`, when present, is a run of decimal digits and limits the
output to the first `n` commits; `0` produces no output at all. Fails if
`<rev>` does not resolve or does not peel to a commit, if `<n>` is not a run
of decimal digits, or if the walk reaches a commit whose object is missing or
damaged.

The walk is git's default order — reverse chronological by **committer**
date, resolving ties in favour of whichever commit was discovered first:

```
list  := [start]                       (a list ordered by decreasing date)
seen  := {start}
while list is not empty:
    pop the first commit c from list and emit it
    for each parent p of c, in header order:
        if p not in seen:
            add p to seen
            insert p into list after every entry whose date >= p's date
                                 and before all the rest
```

A commit's date is the timestamp of its `committer` line. Because
`insert` places equal dates last, the order is fully determined.

Each emitted commit is one line:

```
<40 hex id> SP <author name> SP <author timestamp> SP <subject> LF
```

The author name and subject are the raw bytes defined above; the timestamp is
the author line's seconds value in decimal. A commit with an empty subject
therefore ends in a space.

### `ls-tree <rev> [<path>]`

Resolves `<rev>`, peels it to a tree as `^{tree}` does, then walks `<path>`
when given: `<path>` is one or more names separated by single `/`, with no
leading or trailing `/`, and no component empty, `.` or `..`. Each component
must name a tree entry whose object type is `tree`. Fails if `<path>` does
not have that shape — `.`, `src/`, `/src` and `src//deep` all fail, and so
does the empty path a trailing space produces — if `<rev>` does not peel to a
tree, if a component is missing, or if a component is not a tree. With no
`<path>` the entries of the tree itself are printed.

Prints the entries of that tree, in stored order, one per line:

```
<6-digit octal mode> SP <type> SP <40 hex id> HT <name> LF
```

The mode is the entry's mode as six octal digits with leading zeros, the type
is `blob`, `tree` or `commit` as defined above, and the name is the quoted
entry name — the bare name, never a path.

### `cat-file <rev>`

Resolves `<rev>` to an object, reads it, and **verifies it**: the SHA-1 of its
stored form must equal its id. Fails if the object is missing, cannot be
decompressed, is malformed, or fails that check.

Writes the object's type and size, then its payload verbatim:

```
<type> SP <size> LF
<payload>
```

Nothing follows the payload. The payload is copied byte for byte, so this is
a binary file whenever the object is (a tree's payload contains raw ids).

### `diff <rev1> <rev2>`

Peels both revisions to trees as `^{tree}` does and compares them
recursively. Fails if either does not peel to a tree or if any tree on the
way is missing or damaged.

Each tree is first flattened to a map from full path to (mode, id): a tree
entry contributes its entries recursively under `<name>/`, and every other
entry contributes itself. Then, for every path in either map whose (mode, id)
pair differs:

| in `rev1` | in `rev2` | status |
|---|---|---|
| no | yes | `A` |
| yes | no | `D` |
| yes | yes, same `mode & 0170000` | `M` |
| yes | yes, different `mode & 0170000` | `T` |

Paths present in both with the same mode and the same id produce no line.
There is no rename or copy detection.

Lines are sorted by the bytes of the path, ascending, and printed as

```
:<mode1> SP <mode2> SP <id1> SP <id2> SP <status> HT <path> LF
```

The line begins with a colon immediately followed by the first mode. Modes
are six octal digits and ids are 40 hex digits, using `000000` and forty `0`
digits for the side where the path is absent. The path is quoted as
described above.

### `rev-parse <rev>`

Prints the object id `<rev>` resolves to, as 40 lowercase hex digits and a
newline. Fails when the revision does not resolve.

### `count-objects`

Takes no arguments. Prints exactly three lines:

```
loose: <number of loose object files>
in-pack: <number of objects across all packs>
packs: <number of packs>
```

`loose` counts the files `repo/objects/<xx>/<yyyy…>` where `<xx>` is two
lowercase hex digits and `<yyyy…>` is 38 lowercase hex digits — including
damaged ones, since the count does not read them, and including objects that
are also present in a pack. `packs` counts the `.idx` files that have a
matching `.pack`. `in-pack` is the sum over those packs of the object count
in the index, `fanout[255]`; an object in two packs counts twice. All three
are zero in an empty repository.

## Worked example

`input/commands.txt`:

```
count-objects
rev-parse HEAD
rev-parse main
rev-parse main^
log main
ls-tree main
cat-file b7814cae2e925fe74c6cd5816462fff515ccb256
diff HEAD main
```

against a repository with five loose objects, no packs, a branch `main`
holding two commits, and a detached `HEAD` sitting on the first of them. The
output directory then holds:

`001.out`

```
loose: 5
in-pack: 0
packs: 0
```

`002.out`

```
0f5efe1e004bb7db3eed8d431f1dd464c55070b7
```

`003.out`

```
bc99f2827e555cad8970b6d96d3c0cf224336304
```

`004.out`

```
0f5efe1e004bb7db3eed8d431f1dd464c55070b7
```

`005.out`

```
bc99f2827e555cad8970b6d96d3c0cf224336304 Ada Lovelace 1400003600 Add only.txt
0f5efe1e004bb7db3eed8d431f1dd464c55070b7 Ada Lovelace 1400000000 Empty tree commit
```

`006.out`

```
100644 blob b7814cae2e925fe74c6cd5816462fff515ccb256	only.txt
```

`007.out`

```
blob 9
one file
```

`008.out`

```
:000000 100644 0000000000000000000000000000000000000000 b7814cae2e925fe74c6cd5816462fff515ccb256 A	only.txt
```

The first commit has an empty tree, so `ls-tree HEAD` would write an empty
file, and `diff main HEAD` would report the same path with status `D` and the
two ids swapped.

## Limits

- At most 9999 commands per test.
- Repositories up to about 1100 commits, 4300 objects and 1.4 MiB of packs.
- Individual blobs up to about 450 KiB.
- Delta chains up to git's default depth of 50.
