# kvstore — implementation approach

SPEC.md defines *what* the program produces, byte for byte. This note fixes
*how* it produces it. Nothing here changes behaviour; where this note and
SPEC.md seem to disagree, SPEC.md wins.

Sizes used below: `N` documents in the store, `h` the height of a tree
(`O(log N)`), `C` the number of index entries in a `find` candidate range,
`m` the number of documents a command emits, `L` the number of command lines.

## Overall approach

Read `commands.txt`, `main.tdb` and `main.twal` completely into memory at
start-up. The main file is one in-memory byte buffer; the log is one in-memory
byte buffer that commits append to. Recovery is a single forward pass over the
input log that builds the overlay (page number → newest committed 1024-byte
image). Pages are always held as raw 1024-byte images: in the main-file buffer,
in the overlay, or in the open transaction's dirty set. B+tree operations read
page images through the overlay chain, decode a node into a list of cells only
when they are going to change it, and re-encode the whole page canonically on
write. Commands are parsed and executed one line at a time; each command's
result block is appended to one output buffer. At the end the three output
files are each written once.

`find` collects candidates cheaply first (primary keys only), and fetches and
evaluates documents in primary-key order, stopping as soon as `limit` matches
are found.

## Required choices

1. **Whole-file, in-memory I/O.** Read each input file in one go; keep
   `main.tdb` and the log as growable byte buffers; write `results.txt`,
   `main.tdb` and `main.twal` once each at exit. No file I/O happens while
   commands run (commit appends to the log buffer, checkpoint copies images into
   the main buffer). This keeps I/O cost identical and negligible everywhere.

2. **Page store = byte images, three layers.** `read_page(p)` checks the dirty
   set, then the overlay, then the main buffer, using a hash map or ordered map
   keyed by page number for the first two (`O(1)` or `O(log P)` per read). It
   returns a read-only *view* of the stored image, not a copy. A write stores a
   fresh 1024-byte image in the dirty set. Rollback discards the dirty set and
   restores the header saved at `begin`.

3. **Header as a decoded struct.** Keep the page-1 fields and index directory in
   a decoded struct for the open transaction; encode page 1 only at commit (it
   is always dirty then). Save a copy at transaction start for rollback.

4. **Decode on modify, raw on read.** Search, point lookup and range walks work
   on the page image directly (binary search over the slot array, comparing key
   bytes in place) or on a decoded node whose keys and values are views into the
   image; neither path allocates per cell. Insert, delete, split, borrow and
   merge decode the affected nodes into an ordered list of cells, edit the list,
   and encode each changed node into a new canonical image (§11). No decoded
   node is cached across commands; the page image is the only cached form.

5. **B+tree operations by descent with a path stack.** Insert, replace and
   delete descend from the root recording (page, decoded node, child index) per
   level, then split or rebalance bottom-up along that stack exactly as §12
   prescribes. Each is `O(h)` page decodes/encodes. Read-only lookups descend
   without building a stack. Range walks descend once to the first key `≥ from`
   and then follow leaf `link`s; they never restart from the root per key.

6. **Commit.** Increment the counter, encode page 1, emit the dirty pages in
   ascending page order (sort the page numbers, or iterate an ordered map),
   append each record to the log buffer with its CRC computed incrementally over
   the 20 header bytes followed by the payload (no concatenated temporary), then
   move the images into the overlay. Cost `O(k log k + 1048 k)` for `k` dirty
   pages. CRC-32 is the byte-wise table-driven algorithm with a 256-entry table
   built once.

7. **Checkpoint.** Set the main buffer's length to exactly `page_count * 1024`
   (zero-filling any growth), copy overlay images in ascending page order, clear the overlay, reset the log
   buffer to the 32-byte header. `O(n log n + 1024 n)` for `n` overlay pages.

8. **Values.** A document is fully deserialised into a value tree (null, bool,
   int, string, list, object-as-ordered-fields) when it is needed, and
   serialised once per write. Overflow chains are read by appending each page's
   chunk to one buffer pre-sized to `doc_len`. Predicates are evaluated on the
   value tree. Field paths are split into segments once per parsed command and
   once per live index per command, not per document.

9. **`find` with a `scan` plan.** Walk the primary tree in key order,
   deserialise and evaluate each document, and **stop as soon as `limit`
   matches have been collected**. `limit 0` emits nothing and reads no document.
   Cost `O(N)` documents in the worst case, `O(position of the limit-th match)`
   otherwise.

10. **`find` with an `index` plan: keys first, then fetch in key order.**
    a. Seek the index tree to the start of the candidate range (§17.3: the start
       is the leftmost leaf for `<` and `<=`, the first key `≥ V` otherwise) and
       walk leaves until the first entry past the range (for `>`, first skip
       the entries that have `V` as a prefix), collecting only the primary
       key suffix of each entry. No document is read in this phase. `O(h + C)`.
    b. Sort the collected primary keys byte-wise. `O(C log C)`.
    c. For each key in that order: look it up in the primary tree, deserialise,
       evaluate the whole predicate, keep it if it matches, and stop when `limit`
       matches are kept. `O(h)` per fetched candidate.
    The result is identical to evaluating every candidate and sorting the
    matches, but documents past the limit are never read. `limit 0` skips phase
    (c) entirely (phases a and b may be skipped too).

11. **`scan` command.** Seek to `from` (or the leftmost leaf), walk leaves until
    `to` or, for a forward scan, until `limit` cells are collected. For a
    `reverse` scan collect the in-range cells (key and cell reference only),
    reverse, then truncate. Deserialise documents only for the rows actually
    emitted, and not at all for `keys`. Cost `O(h + cells walked + m)`.

12. **`create index`.** After the `index-exists` and `index-limit` checks, one
    walk of the primary tree in key order computes every
    entry key and **stops at the first key longer than 128 bytes** (failing with
    `index-key-too-long`). On success, insert the entries computed by that walk,
    in that same (primary-key) order, with the ordinary insert — no second walk
    and no second deserialisation. `O(N)` document reads plus `O(E · h)` for `E`
    entries.

13. **Index maintenance.** On each write compute the old and new entry keys per
    live index from the old and new value trees and apply §14.3 directly: equal
    keys mean no tree operation. `O(I · h)` per write for `I` live indexes. The
    old document is deserialised at most once per command, before the primary
    tree is modified: `update` and `unset` reuse the old document they read
    to build and validate the new one, `delete` reads it once, and `put` deserialises it only when at least
    one index is live (with none, it only walks the old overflow chain to free
    it).

14. **Output.** Each result block is formatted straight into one growing output
    buffer (or a buffered writer); document rendering writes into that buffer
    rather than building and concatenating many intermediate strings. Total
    `O(output size)`.

## Left to the implementer

- Container choices: hash map or ordered map for the overlay and dirty set;
  vectors, slices or arrays for cells; owned buffers versus views wherever item 4
  does not forbid a per-cell allocation.
- The value-tree representation (tagged union, class hierarchy, enum), how
  object fields are stored (any representation that preserves the canonical
  order of §4), and integer types.
- Whether phase 10b sorts at all for `==`: entries sharing the prefix `V` are
  already in primary-key order, so the sort may be skipped there.
- Parser structure (hand-written lexer plus recursive descent is expected; the
  exact shape is free), error representation (exceptions, result types, error
  codes), module layout and naming.
- Micro-optimisations that do not change the algorithms above: buffer reuse and
  pre-sizing, inlining, avoiding bounds checks, small-string tricks, reading
  integers with unaligned loads.

## Pitfalls

- Evaluating every `find` candidate and only then sorting and truncating to
  `limit`. With small limits and wide ranges (`age < 70 limit 8`) this reads
  thousands of documents to emit a handful; collect keys, sort, then fetch until
  the limit is met (item 10).
- Walking and deserialising the whole store for a `scan`-plan `find` that has a
  `limit`, or for `limit 0`. Stop at the limit (item 9).
- Continuing the `create index` walk after a too-long key has been seen, or
  walking and deserialising the store twice (once to validate, once to insert).
- Copying the 1024-byte image on every page read, or decoding a page into
  freshly allocated per-cell key/value buffers just to binary-search it. Point
  lookups happen `h` times per candidate and per write; these copies dominate
  read-heavy scripts.
- Building a full path stack of decoded nodes for read-only lookups.
- Deserialising the old document on every `put` replace even when no index is
  live, or deserialising it a second time inside the write after `update` or
  `unset` already read it for validation.
- Re-descending from the root for each key of a range walk instead of following
  leaf links; seeking from the leftmost leaf when a `from` key is given.
- Deserialising documents for `scan ... keys`, or for rows that a `reverse` or
  `limit` will drop.
- Re-reading or re-scanning the log to serve reads; the overlay is the only
  view of the log after recovery.
- Building log records or CRC input by concatenating header and payload into a
  new buffer, or growing the log or output buffer by repeated whole-buffer
  copies (immutable-string `+=` in a loop) instead of amortised append.
- Pre-sorting index entries by index key in `create index` (this is a
  behaviour error, not only a performance one: page numbers change).
