# typeset — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

A strictly layered, single-pass pipeline. Load the nine faces and the active
pattern set into flat lookup tables; parse `settings.cfg`; read
`document.cdx` whole and parse it line by line into a block tree whose inline
text is already resolved into styled character runs. Walk the tree once,
building each horizontal list once, breaking it with the specified total-fit
algorithm over **prefix sums**, setting its lines, and appending vertical
items to one flat array (footnote lines and figure blocks are laid out once,
when first met, into side tables). Paginate the body with one forward scan
over that array, then build and paginate the TOC, then format every page's
items, sort them and write each output file with one write.

Sizes below: `I` is the number of items in one horizontal list, `B` its
number of breakpoints, `N` the number of break nodes created (`N <= 4B`),
`A` the size of the pass-1 active set (nodes within about one measure of the
current breakpoint), `V` the number of vertical items, `P` the number of
output items.

## Required choices

1. **Input and resources.** Each input and data file is read whole in one
   call and split into lines by scanning for `\n`. Glyph advances are a
   dense array per face indexed by code point, sized to the largest listed
   code point, with `default` for anything outside; kerns are one hash map
   per face keyed by the packed pair `(a << 32) | b` (or a dense table when
   every kerned code point is small). Faces are referred to by a small integer index everywhere,
   never by name string; the name is used only when output is formatted.
2. **Hyphenation.** Liang patterns are held in a trie over the 27 symbols
   `a`-`z` and `.`, or in a hash map keyed by an integer packing of the key
   (keys are at most a handful of letters); a lookup never allocates a
   substring. Results are memoised per distinct lowercased segment in one
   hash map (segment to break positions), so each distinct word is
   hyphenated once per run. Liang on a segment of length `n` is
   O(n · maxkey).
3. **Horizontal lists, O(I).** One growable array of compact, kind-tagged
   items per list (box width and fragment id, glue `w/y/z/infinite`,
   penalty `p/flagged/pre-break width`). Box widths are computed once, when
   the box is built, by the single-`scale` rule. Text for output is kept once
   per box in the output encoding (UTF-8) and is not re-encoded later.
4. **Prefix sums per list.** After building a list, compute in one pass the
   prefix arrays of width, stretch, shrink and infinite-glue count over the
   items, a "next non-glue item" array for skipping leading glue, and the
   list of breakpoint indices. `W`, `Y`, `Z` and the infinite flag of any line
   `(a, b)` are then O(1): sums at `b` minus sums at the line's first
   non-glue item, plus the pre-break width of `b`. These arrays are shared by
   both passes, by table-cell `nat`/`min` measurement and by line setting.
5. **Line breaking, the node table.** Nodes are compact records (breakpoint
   item index, fitness class, flagged, `int64` total, predecessor index, and
   the line-start position or its prefix sums) in one growable array. The
   active set is one integer array in node-creation order, compacted in
   place each breakpoint; new nodes are appended at its end, which keeps the
   creation order the tie-breaking rule needs (strict `<` when choosing the
   best candidate). The inner loop reads only the node record, the prefix
   arrays and the current breakpoint, never the item array. Badness is exact
   integer arithmetic: clamp to 10000 at once when `d >= 5Y`, use 64-bit
   arithmetic when `Y^3` fits, and a 128-bit (or equivalent exact) path
   otherwise, with no heap allocation. The final node is chosen by one scan
   of the nodes at the final breakpoint in creation order with strict `<`
   on the total, which realises the class-then-node-number tie rule.
6. **Pass 1 pruning and early exit, O(B · A).** In pass 1, a node whose line
   to the current breakpoint, *excluding* the pre-break text, has
   `W - Z > L` is removed from the active set for good (widths only grow).
   If the active set becomes empty, pass 1 stops at once and pass 2 runs.
7. **Pass 2, O(B · N).** Pass 2 rebuilds the node table from scratch and
   evaluates every node created so far at every breakpoint; it is not
   pruned. This quadratic cost is inherent to the specification and is the
   same work in every implementation.
8. **Each list is broken once.** Paragraphs, items, headings, captions,
   footnotes, TOC entries and table cells are each built and broken exactly
   once. A table cell's list is built once, measured for `nat` and `min` from
   its prefix sums, and then broken at the column width from the same list.
   A figure block is laid out once (its height does not depend on `y`) and
   stored with its baselines relative to its top; footnote lines are stored
   once per footnote. Pagination only reads these results.
9. **Vertical list.** One flat array of compact vertical items; a `LINE`
   refers to its set line by index or reference rather than carrying a copy.
   Break legality (orphans, widows, heading groups, keep runs) is computed
   once per vertical list into a boolean array in O(V).
10. **Page breaking, linear per page.** The cut for a page is found
    by one forward scan from `i` that advances the placement recurrence
    incrementally (cursor, previous baseline, previous depth, used height
    without trailing glue) and adds each referenced footnote's lines to an
    incrementally maintained footnote stack height. The scan stops at the
    first `j` with `used(j) > goal`, so each page examines about one page
    of items plus one; only the no-legal-cut fallback scans further. The
    footnote split of step 5 computes
    the stack's cumulative heights once per page and takes the prefix by one
    linear scan. The figure queue is a FIFO with O(1) pop.
11. **TOC after body.** Body page labels do not depend on the number of
    front pages, so the body is paginated once, then the TOC list is built
    from the recorded heading pages and paginated once. There is no
    fixed-point iteration.
12. **Output, O(P log P).** For each page, each item is formatted once into
    bytes and stored with its numeric key `(region, y, x, kind)`; the page's
    items are sorted with integer comparisons, falling back to comparing the
    formatted bytes only on equal keys. All of `layout.txt` is appended into
    one buffer (or one large buffered writer) and written once; likewise
    `report.txt`. Integers are written by a direct integer-to-decimal
    conversion.

## Left to the implementer

- Container types, struct layout, naming, module structure, and how the
  block tree and inline runs are represented.
- Trie versus packed-key hash map for patterns; hash function choice; the
  dense-array bound for glyphs and whether kerns use a hash map or a table.
- Whether prefix sums are stored per item or only at breakpoints, and
  whether a node stores the line-start index or the sums at that start.
- Whether the inline scanner works on bytes or decoded code points, as
  long as it is one linear pass per block.
- How the sort is implemented (any O(P log P) sort; stability not needed
  because the key ends with the full line text).
- Loop-level micro-optimisations: bounds-check elimination, `int32` indices,
  unrolling, arena or pooled allocation.

## Pitfalls

- Scanning items to skip leading glue, or touching large item records, in
  the line-breaking inner loop; this loop runs tens of millions of times on
  long paragraphs, and any per-candidate work beyond a few array reads
  dominates.
- Allocating per breakpoint: a fresh "kept nodes" array each step, or
  appending to an array that was just shortened in a language where that
  reallocates or copies, instead of compacting one array in place.
- Copying whole node or vertical-item records by value in hot loops where
  the records are large.
- Omitting the pass-1 overfull pruning (pass 1 becomes O(B · N)), or pruning
  in pass 2 (wrong results).
- Looking up hyphenation patterns by allocating substring keys, with a slow
  general-purpose string hash, and repeating the full Liang scan for every
  occurrence of a word.
- Looking up glyph advances through a general hash map per character, and
  naming faces by strings that are compared or hashed in inner loops.
- Allocating a separate small heap object (string, array, record) per box,
  run, line or output item where a slice of, or index into, a shared buffer
  would do; in a garbage-collected runtime this shows up as collector time.
- Storing text in one encoding and converting each box to another encoding
  when lines are set or output is formatted.
- Recomputing the used body height or the footnote stack from `i` for every
  candidate `j` (quadratic per page), or re-deriving keep runs and legality
  per candidate.
- Building output lines by repeated concatenation of temporaries, formatting
  inside the sort comparator, or writing per item without buffering.
- Laying out a figure block or breaking a footnote or table cell again each
  time it is considered for a page.
