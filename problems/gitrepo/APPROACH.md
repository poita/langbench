# gitrepo — required approach

SPEC.md defines what the program does; this note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Open the repository once and keep everything that is decoded for the whole
run: every command in `commands.txt` is answered by one long-lived repository
object. At start-up, read each usable `.idx` and `.pack` file whole into
memory and list the loose object directories once. Objects are read through a
single object store that inflates with a table-driven DEFLATE decoder,
reconstructs deltas recursively, and memoises every reconstructed object by
its pack position (so delta bases are decoded once) and by id. On top of it
sit two parsed-object caches, commits and trees, which `log`, revision
resolution, `ls-tree` and `diff` use exclusively. `log` walks history with a
binary heap; `diff` flattens both trees into path lists, sorts them and
merge-joins them. Each command's answer is built in one in-memory byte buffer
and written to its output file with a single write.

Sizes below: `B` is the total size of the pack and index files, `N` the number
of objects in the repository, `C` the number of commits, `S` the size of an
object's payload, `D` the depth of its delta chain, `E` the number of entries
in a flattened tree, `k` the number of commits a `log` emits and `F` the size
of its pending list.

## Required choices

1. **One repository object for the whole run.** Packs, indexes, the loose
   object listing, the parsed `packed-refs`, and all caches below live for the
   entire process and are shared by all commands. Nothing is re-read or
   re-parsed per command, so a command list that walks the same history many
   times costs one inflate and one parse per commit, not one per visit.
2. **Pack and index files read whole, once.** Read each `.idx`/`.pack` pair
   into a byte array (or map it) at start-up, check the headers, and index into
   the arrays thereafter. Index lookup is the fanout range plus a binary search
   comparing 20 raw bytes in place, O(log N), with no per-probe copy or hex
   conversion.
3. **Loose objects listed once.** At start-up, list `objects/<xx>/` once and
   keep the ids of the regular files with well-formed names (SPEC's
   `count-objects` rule) in a hash set. "Is it loose?"
   is a set lookup; the file is opened only to read an object that is in the
   set. The same listing answers `count-objects` and feeds the abbreviation
   index. The repository is not modified during the run, so this is exact.
4. **Inflate as in `problems/inflate/APPROACH.md` (items 2–11).** A 64-bit
   LSB-first bit buffer; two-level Huffman lookup tables (root 10 bits for
   literal/length, 8 for distance) rebuilt in reusable buffers per dynamic
   block; fixed-code tables built once; non-overlapping back-references copied
   as one block copy. Decoding starts at an offset inside the pack array (no
   copy of the remaining pack) and stops at the final end-of-block symbol;
   bit-buffer refills that run past the stream are harmless but must stop at
   the end of the array. The output array is preallocated to the size in the
   pack object header (geometrically grown for loose files). That size is only
   a capacity hint, capped at a sane bound: the output still grows past it and
   a mismatch is not itself an error. The Adler-32 trailer is not checked.
   Inflate is O(compressed + S).
5. **Delta reconstruction, O(delta + result).** Read the two size varints
   (the base size is skipped, not checked), allocate the result once at the
   declared result size (output beyond it is a failure), execute copy
   instructions as block copies out of the base and insert instructions as
   block copies out of the delta, then check the length. Bounds are checked
   per instruction, not per byte.
6. **Object cache keyed by pack position.** Every object reconstructed from a
   pack (type plus payload) is memoised under (pack, offset) for the rest of
   the run, and `OFS_DELTA` bases are fetched through this cache, so a chain of
   depth `D` is decoded once and every later object on or above it costs one
   inflate and one delta application. A lookup by id checks the loose set
   first (a loose copy wins), then the packs in one fixed order, and goes
   id → (pack, offset) → cache; loose objects are memoised by id. `REF_DELTA`
   bases go through the same lookup by id. Cached payloads are shared, never
   copied on a hit. Failures may be memoised as failures. With the spec's size
   limits the whole repository fits; no eviction is needed.
7. **Parsed commit cache.** A commit is parsed once into its parent ids, tree
   id, committer timestamp, and its ready-to-print log line suffix (author
   name, author timestamp and subject, i.e. everything after the id), and that
   record is kept by id for the run. The walk, `^`/`~` resolution and peeling
   all read this record; nothing re-parses commit text or recomputes subjects.
8. **Parsed tree cache.** A tree is parsed once into its entries (mode as an
   integer, name bytes, 20-byte id, entry type) and kept by id. `ls-tree`
   path walks, `^{tree}` peels and `diff` flattening read entries from this
   cache.
9. **`log` with a binary heap, O(k log F) after warm-up.** The spec's ordered
   list is exactly a priority queue keyed by (committer date descending,
   insertion sequence number ascending): give every pushed commit the next value
   of a per-walk counter and pop the maximum. Use the language's binary heap or
   a hand-written one. `seen` is a per-walk hash set of ids (or a stamped
   array indexed by a dense commit number). The commits loaded are exactly
   those of the spec's walk cut at the limit: the start commit (also for
   `n = 0`), and, after each emitted commit including the `n`-th, every unseen
   parent, whose record is needed for its date when it is pushed; then the walk
   stops and never touches the rest of the history. A missing or damaged commit
   among those fails the command. Each emitted line is the 40 hex digits of the
   id followed by the cached suffix.
10. **`diff` by flatten, sort and merge-join, O(E log E).** Flatten each side
    recursively from the tree cache into a list of (path, mode, id), building
    each path once from its parent prefix plus the name; only entries of
    object type `tree` are descended into (gitlinks are leaves). Sort each list
    by the path bytes (unsigned) with the standard sort, then walk both lists
    with two cursors, emitting `A`, `D`, `M` or `T` lines in path order. Every tree on both sides is read, as the spec
    requires; identical subtrees are not skipped.
11. **Abbreviation index, built once.** On the first abbreviated id, build a
    sorted, de-duplicated array of all object ids (loose set plus every index's
    id table). Each abbreviation is then two binary searches for the prefix
    range, O(log N); 0 or more than 1 hits fail. Full 40-digit ids use the
    loose set and the index binary search.
12. **Refs.** Parse `packed-refs` once into a hash map. Loose ref files are
    read when a name is tried; the at most six patterns per name each cost one
    small file probe. Results may be memoised per name.
13. **SHA-1 for `cat-file`, streaming, O(S).** Feed the header
    (`<type> <size>\0`) and then the cached payload into one SHA-1 state
    processing 64-byte blocks directly from the buffers, with a fixed message
    schedule array reused for every block and padding applied only to the final
    partial block. Never build a concatenated copy of header plus payload.
    Verification is done on every `cat-file`.
14. **Output.** Build each answer in one growable byte buffer: ids converted to
    hex with a lookup table, numbers formatted directly into the buffer, path
    quoting appended in place. Write the file with one write call (or
    one buffered writer flushed once). Do not memoise command outputs or other
    per-command results (walk results, flattened trees); every command does its
    own walk, flatten and formatting.

## Left to the implementer

- Whether ids are held as 20-byte arrays, two integers, or 40-character hex
  strings, and which hash function the maps use.
- Whether pack files are read into memory or memory-mapped; whether start-up
  work (pack loading, loose listing) is eager or lazy on first use.
- Container types, struct and class layout, whether cache entries are shared
  through references, reference counting or indices into an arena, and how
  failures are signalled (exceptions, result types, error flags).
- Whether the commit cache stores the log line suffix as one byte string or as
  separate name/time/subject fields, as long as nothing is recomputed per visit.
- Whether `seen` is a hash set or a stamped array; whether the heap is from the
  standard library or hand-written.
- Micro-optimisations inside inflate, delta application and SHA-1 (unrolled
  rounds, unaligned loads, unchecked indexing where safe), and module
  structure and naming.

## Pitfalls

- Opening a fresh repository object, or clearing caches, per command; or
  keeping a commit cache that lives only for one `log` call. History walks then
  re-inflate and re-parse every commit on every walk, several times slower on
  history-heavy command lists.
- No cache keyed by pack position: every read of a deltified object re-decodes
  its whole base chain (up to 25–50 inflates and delta applications for one
  object), and a cache keyed only by requested id never catches the bases.
- Probing the filesystem (`exists`/`stat`/open) for a loose copy before every
  object read, and listing a loose directory again for each abbreviated id or
  `count-objects`.
- Caching raw objects but re-parsing the commit text (headers, ident lines,
  subject) on every visit, including parsing a parent a second time just to
  read its date.
- Keeping the `log` pending list as an array and inserting by linear scan plus
  rebuilding the array by concatenation (`list[0..i] ~ x ~ list[i..]`) or
  removing from its front with a shifting delete: each step copies the whole
  list.
- Bit-at-a-time canonical Huffman decoding, single-level 2^15-entry tables
  rebuilt per block, and growing the inflate output by a per-byte append that
  re-checks capacity, as listed in the inflate note.
- Copying the rest of the pack into a new array to inflate one object, or
  copying a cached payload on every hit.
- Building the SHA-1 input by concatenating header and payload into a new
  buffer, or allocating the message schedule per block.
- Hashing full path strings into two maps and then sorting the union of their
  keys, instead of sorting two lists and merge-joining; or pruning equal
  subtrees in `diff`, which skips reading trees the spec requires to be read.
- Formatting output with many small string concatenations that each copy the
  line so far, or writing each output line with a separate system call.
