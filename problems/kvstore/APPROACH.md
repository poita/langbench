# kvstore: required approach

SPEC.md defines what the program produces; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` documents in the store, `h = O(log N)` the height of a tree, `C` the
index entries in a `find` candidate range, `m` the documents a command emits.

## Algorithm

A page-based B+tree store with a write-ahead log. Recovery is one forward pass
over the log that maps each page number to its newest committed image; a page
is read from the open transaction's dirty pages, then that map, then the main
file. The primary tree and each index are B+trees over canonical pages (§11),
searched, split and rebalanced by descent from the root as §12 prescribes.
Documents are deserialised into value trees, against which predicates are
evaluated. Commands are parsed by recursive descent and run one line at a
time.

## Required rules

1. **Reads never rescan the log** after recovery.
2. **A range walk is O(h + cells walked)**: one descent, then leaf order.
3. **`find` and `scan` stop at the limit** and deserialise only the documents
   they evaluate or emit (none for `keys`); `limit 0` reads no document.
4. **An `index` plan collects primary keys before reading documents**, then
   fetches them in primary-key order: O(h + C log C) plus O(h) per fetched
   document.
5. **`create index` reads the primary tree once.**

## Complexity

Point lookup, insert, replace and delete are O(h) page reads and writes, plus
O(I·h) index maintenance for `I` live indexes. `scan` is O(h + cells walked + m).
`find` reads O(N) documents with a `scan` plan, or the costs of rule 4 with an
`index` plan, either way ending at the `limit`-th match. A commit of `k` dirty
pages is O(k log k + k·page size); a checkpoint is linear in the log's page map.
