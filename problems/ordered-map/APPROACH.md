# ordered-map — required approach

SPEC.md defines what the program does; this note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input into memory once and walk it with a byte cursor.
Keep the map in a single AVL tree augmented with subtree sizes, whose nodes
live in one index-addressed pool with index 0 as a nil sentinel. Insert and
delete are recursive descents that rebalance on the way back up; every query
(get, floor, ceil, succ, pred, rank, select, min, max) is one iterative
root-to-leaf walk; `range` is a pruned in-order traversal that formats keys
straight into the output. All output goes into one byte buffer that is written
to standard output once at the end.

Sizes below: `Q` is the number of commands (at most 200 000), `n` the number of
keys currently in the map (at most `Q`), and `r` the number of keys printed by
one `range`.

## Required choices

1. **Tree: AVL, size-augmented.** Each node holds its key, its value, left and
   right child indices, its subtree height and its subtree size. Heights and
   sizes are recomputed from the children after every structural change and
   rotation. AVL keeps the depth near `1.44·log₂ n`, which is what every query
   walk pays for; do not use a treap, skip list, red-black tree, B-tree, splay
   tree, or a sorted array with insertion by shifting.
2. **Node pool.** Nodes live in one contiguous pool (an array of node records
   or parallel arrays of fields, implementer's choice) addressed by 32-bit
   integer indices. Index 0 is a sentinel with size 0 and height 0, so child
   lookups never need a null check in the size and height arithmetic. Reserve
   capacity for `Q + 1` nodes up front (no command adds more than one node).
   Reusing freed slots through a free list is allowed but not required. No
   per-node heap allocation and no pointer-linked nodes owned by a garbage
   collector or reference counter.
3. **Values are not copied into separate allocations.** The input buffer is
   kept alive for the whole run, and a node stores its value as a reference
   into it (a slice, or an offset and length), or inline in a fixed 32-byte
   field in the node. Replacing a value on `insert` of an existing key just
   overwrites that reference.
4. **Insert, O(log n).** One recursive descent. If the key is found, replace
   the value, report `updated`, and return without touching heights, sizes or
   balance on the way up. Otherwise create the node at the leaf and, on the
   way up, recompute height and size and apply the standard single or double
   rotation where the balance factor reaches ±2.
5. **Delete, O(log n).** One recursive descent. If the key is absent, report
   `missing` and return without any updates on the way up. A node with at most
   one child is replaced by that child. A node with two children takes the key
   and value of its in-order successor (the leftmost node of its right
   subtree), and that successor is then removed from the right subtree. On the
   way up recompute height and size and rebalance as for insert.
6. **Queries, iterative, O(log n), no allocation.**
   - `get`: plain search.
   - `floor`/`pred`: walk down remembering the last node whose key is ≤ (or <)
     the argument, going right from it and left otherwise. `ceil`/`succ` are
     the mirror image. These compare against the argument and never compute
     `key ± 1`, which keeps the extreme keys safe.
   - `rank`: walk down; whenever the argument is greater than the node key,
     add `size(left) + 1` and go right, otherwise go left.
   - `select k`: first answer `missing` if `k ≥ size(root)` (this also covers
     `k` up to 10⁹), then walk down comparing `k` with `size(left)`.
   - `min`/`max`: leftmost/rightmost walk. `size`: the root's size field.
7. **Range, O(log n + r).** If `lo > hi` print `empty` without touching the
   tree. Otherwise do an in-order traversal from the root that descends left
   only when the node key is > `lo` and right only when it is < `hi`, and
   appends each key in `[lo, hi]` directly to the output buffer, preceded by a
   space except for the first. Do not collect the keys or nodes into a
   temporary list first, and do not locate the start with a search and then
   step through successors one search at a time.
8. **Input.** Read all of stdin in one bulk read (or one buffered read loop
   into a single growing buffer). Scan it with a cursor: find the end of each
   line and the separating spaces directly. Dispatch on the command by its
   first byte, then one more byte where that is ambiguous (the second byte
   splits `size`/`succ`/`select` and `min`/`max`; the fourth byte, or the
   token length, splits `range`/`rank`); do not compare whole command strings
   one after another or look them up in a string-keyed table.
9. **Integer parsing.** Parse keys by hand from the bytes: an optional `-`,
   then digits accumulated in an unsigned 64-bit value (or on the negative
   side of a signed one) and negated at the end, so −9223372036854775808
   parses without overflow. Do not create a substring and call a general
   string-to-integer conversion per token. Parse `select`'s `k` the same way
   into a 64-bit value.
10. **Output.** One growable byte buffer for the whole run, appended with
    amortised O(1) bulk copies, written to stdout once at the end (a buffered
    writer of at least 64 KiB that is flushed only when full and at exit is
    equivalent). Each append's fast path (capacity check and copy) is inline
    in the caller; where the language's built-in array append is an
    out-of-line runtime call, keep the buffer as a byte array with an explicit
    length and capacity and copy into it directly. Keys are
    formatted by writing digits into a small fixed scratch buffer (handling the
    minimum key via an unsigned magnitude) and copying the result into the
    output buffer in one append; a language's standard append-integer-to-buffer
    routine is equally fine as long as it allocates nothing per call. Fixed
    responses (`ok\n`, `missing\n`, ...) are appended as constant byte strings.

## Left to the implementer

- Array of node structs versus parallel field arrays, field widths (32-bit
  sizes and indices are sufficient; height fits in a byte), and whether value
  references are slices, offset/length pairs or inline bytes.
- Whether the rebalance step is one function or split into insert- and
  delete-specific variants, whether balance is tracked as height or as a
  balance factor, and whether the successor removal in delete is a separate
  "delete minimum" routine or a second call of delete.
- Whether the range traversal is recursive or uses an explicit stack, and
  whether the query walks share a helper with flags or are separate functions.
- Free-list reuse of deleted node slots.
- Naming, module structure, globals versus a tree object, bounds-check
  elimination and similar loop-level micro-optimisations, as long as the
  algorithms and complexities above are unchanged.
- Tolerating a trailing `\r` or a missing final newline (the latter is
  required by SPEC.md; the former is harmless).

## Pitfalls

- An unbalanced BST, or a sorted array/list with insertion and deletion by
  shifting: O(n) per mutation, quadratic on the sorted-insertion tests.
- Computing rank by walking the tree in order, or select by stepping `k`
  successors: O(n) per query instead of O(log n) via subtree sizes.
- Copying each value into its own heap string on every insert or update, which
  adds an allocation (and, with a garbage collector, tracing work) per
  mutation.
- Appending to the output through a built-in growable-array append that is an
  out-of-line runtime call (several per key: separator, digits, newline); with
  millions of range keys this call overhead dominates. Use a buffer with an
  inline capacity check and copy, as rule 10 requires.
- Formatting each key into a freshly allocated
  string (or building each range line as a list of strings joined at the end)
  instead of appending digits into the output buffer.
- Collecting a range's keys into a temporary array and formatting them in a
  second pass, or doing a separate `ceil`/`succ` search per emitted key.
- Searching for the key first and then descending again to insert or delete
  it: two root-to-leaf walks per mutation where one suffices.
- Not short-circuiting an `insert` that only updates a value or a `delete` of a
  missing key: recomputing heights and sizes and attempting rebalances along
  the whole path for an unchanged tree.
- Dispatching commands by comparing full command strings in sequence, or
  splitting every line into a list of new string tokens.
- Computing `key + 1` or `key − 1` for `succ`/`pred`, which overflows at the
  extreme keys; and handling the minimum key by negating a signed value.
- Reading stdin line by line through an unbuffered stream, or writing and
  flushing output per command.
