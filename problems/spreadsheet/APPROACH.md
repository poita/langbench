# spreadsheet: implementation approach

SPEC.md defines what the engine does. This note fixes how it is done. Where the
two seem to conflict, SPEC.md wins.

Sizes used below: `I` bytes of input, `L` length of one formula, `C` cells that
exist in the sheet (set, or referenced by some formula or range), `A` the
affected set of one edit (the edited cell plus everything that transitively
reads it), and `E_A` the total length of the dependency lists of the cells in
`A`. A range contributes one dependency per covered cell.

## Overall approach

Every cell gets a dense integer handle when it is first named. Per-cell data
lives in arrays (or one array of records) indexed by that handle. A `set` that
holds a formula parses it once with a recursive-descent parser into a compact
AST whose references are already resolved to handles and whose ranges are
already normalised. The formula's deduplicated dependency list (ranges
expanded) is stored on the cell, and the reverse edges are stored on the
cells it reads. After each `set` or `clear`, the engine recalculates eagerly
and incrementally. An iterative traversal over reverse edges collects the
affected set `A`. An iterative Tarjan SCC pass then runs over the subgraph
induced by `A`, following forward dependency edges. Each component is handled
the moment Tarjan emits it: a cyclic component gets `#CYCLE!`, and a single
non-cyclic formula cell is evaluated by interpreting its AST against the
stored values of the cells it reads, and a literal or empty cell takes its
literal (or empty) value. Tarjan emits components dependencies-first, so those
values are already current. `get` reads a stored value. `dump` sorts the
non-empty cells by row-major key and formats them. All output goes into one
buffer that is written once at the end.

## Required choices

1. **Cells are addressed by dense integer handles.** Map a cell name to a key
   such as `row * 703 + col`, whose numeric order is the row-major dump order.
   Map the key to a dense handle once, through a hash map or a flat table of
   `10000 * 703` entries (keys reach `9999 * 703 + 702`). After that, all
   per-cell state (content, value, dependency list, dependents list,
   traversal marks) is reached by array indexing on the handle. Hash lookups happen only while a command's cell
   name or a formula's references are being resolved, never during
   recalculation or evaluation.
2. **Formulas are parsed once, at `set` time, into a resolved AST.** A
   single-pass tokenizer feeds a recursive-descent parser with one function
   per precedence level, following the SPEC grammar. `REF` leaves hold the
   target handle. Range arguments hold their normalised corners, or the
   precomputed list of covered handles. A formula with an invalid reference is
   marked `#REF!` and gets no dependencies. Number literals are converted once
   with a correctly rounded string-to-double routine. Evaluation never
   re-tokenises or re-parses text.
3. **Dependencies are explicit, deduplicated edge lists in both directions.**
   On `set`, collect the handles of all references and of every cell covered by
   each range, then deduplicate them with a sort followed by a unique pass, or
   with a per-cell stamp array. Store the result as the cell's forward list. Add
   the cell to the dependents list of each target. Record a self-dependency
   (the cell appears in its own list) as a flag, or detect it during the SCC
   pass. Do not deduplicate through a freshly built hash set per formula. On
   `set` or `clear`, first remove the cell from the dependents list of each of
   its old dependencies by swap-remove (a linear search for its position, or
   an O(1) lookup in a stored back-index). The cost is O(L + range cells) per
   edit, plus the length of the searched dependents lists when no back-index
   is kept.
4. **Recalculation is incremental and eager.** After each `set` or `clear`,
   find `A` with an iterative DFS or BFS over dependents lists from the edited
   cell, using an explicit stack or queue and a per-cell mark. Then run an
   **iterative** Tarjan over `A` that follows forward edges and skips every
   target that is not marked as in `A`. The membership test is an O(1)
   array/stamp lookup. Every cycle whose status can change lies inside `A`, so
   no other cell is visited. A component with more than one cell, or a single
   cell that depends on itself, gets `#CYCLE!` for all its members. Any other
   component is evaluated immediately. One edit costs O(|A| + E_A) plus the
   cost of evaluating `A`'s formulas, and nothing outside `A` is touched.
5. **Scratch state is reused and reset in O(|A|).** The Tarjan index, lowlink
   and on-stack data, the "in `A`" mark, and the work stacks are arrays indexed
   by handle (or by position in `A`) that persist across edits. After each
   recalculation, reset exactly the entries of the cells in `A`, or use a
   generation counter so a stale stamp means "unset". Never allocate or clear
   structures sized to the whole sheet on every edit. Never build a fresh hash
   map or a per-node adjacency list for each edit.
6. **There is no cell-to-cell recursion.** Evaluating a formula interprets
   only that formula's AST recursively. Its depth is bounded by the formula's
   length (about 100 levels of nesting, but a left-associative chain such as
   `A1+A2+...+A300` is a left spine hundreds of nodes deep), which a default
   native stack handles; a runtime with a low default recursion limit raises
   it.
   A `REF` reads the referenced cell's stored value and never evaluates that
   cell on demand. Chains of 10,000 cells are therefore handled by the
   iterative traversals in item 4, with no deep call stack and no
   enlarged-stack thread.
7. **Values are a small tagged union: empty, number, string or error code.**
   Producing or reading a number or an error never allocates. Strings are
   immutable, and reading a string cell or literal shares the stored string
   (reference-counted, garbage-collected immutable string, slice or interned
   handle) instead of copying its bytes. Only `&` builds a new string, by
   appending both text forms (numbers formatted directly into it) to one new
   buffer.
8. **Aggregates stream over their arguments in one pass.** A range is walked
   in row-major order over its precomputed handles, or over its corners with
   handles found through the flat table, reading stored values directly. The
   pass keeps running `count`, `sum` (added left to right), `min` and `max`,
   and stops at the first error. Do not collect the numbers into a temporary
   list. Do not evaluate the cells of a range: their values are already
   current.
9. **Numbers are formatted with an integer fast path and a correctly rounded
   10-significant-digit conversion.** Zero gives `0`. Integral values with
   `|v| < 1e15` are converted to a 64-bit integer and printed in decimal. All
   other values use the platform's correctly rounded `%.10g`-equivalent
   conversion (or `%.9e` digits rearranged per the SPEC rule), written straight
   into the output buffer or into a small stack buffer.
10. **I/O is bulk.** Read all of stdin at once. Split lines by scanning for
    `\n` and take slices rather than copying each line. Dispatch on the first
    letter of the command. Append every output line to one growable byte buffer
    and write it with a single call at exit. `dump` collects the handles of
    the non-empty cells, sorts them by row-major key (O(C log C)), and appends
    `name value` lines into the same buffer.

## Left to the implementer

- Whether the key-to-handle map is a hash map or a flat table, and whether a
  handle stays reserved after its cell is cleared (it may).
- AST layout: a node array with integer child indices, boxed nodes, or a
  closure tree built once at `set` time (under a tracing collector, see the
  allocation pitfall below). Whether a range node stores its
  covered handles or only its corners.
- How dependents are stored (vectors, or vectors plus a back-index for O(1)
  removal), and how self-dependency is detected.
- Whether `A` is found by DFS or BFS, and whether Tarjan state is indexed by
  handle or by position in `A`.
- Whether `dump` sorts on every call or caches the sorted order until the set
  of non-empty cells changes.
- Error representation (error codes or singletons), module structure, naming,
  and micro-optimisations such as small-string storage, reserving capacity or
  skipping bounds checks.

## Pitfalls

- Testing "is this dependency in the affected set" with a hash-map lookup
  inside the Tarjan inner loop, or keeping cells in a hash map and reading
  every range cell through it. On densely interconnected sheets these lookups
  dominate the run time several times over.
- Allocating a new hash map, a vector of per-node adjacency vectors, or a
  temporary number list on every edit or every aggregate evaluation, or a
  hash set to deduplicate each formula's dependencies.
- Growing arrays one element at a time in a runtime where truncating an array
  and then appending to it reallocates and copies (for example, slices that
  refuse to stomp past their length). Used as Tarjan or DFS stacks, or as
  dependents lists, this becomes quadratic copying plus heavy collector
  traffic. Use a stack whose capacity survives pops.
- Evaluating cells lazily through recursive calls from cell to cell. This
  needs a call stack 10,000 frames deep, and those deep frames are scanned on
  every garbage collection. Use the iterative topological order instead.
  Writing Tarjan recursively has the same problem.
- Allocating a heap object per AST node and per cell under a tracing
  collector when an array of plain records would do. Allocating a fresh string
  for every number display during `dump`, instead of formatting into the
  output buffer.
- Clearing or reallocating scratch arrays sized to the whole sheet on each of
  thousands of point edits. This makes a sheet of `C` cells cost O(C) per
  edit regardless of how small `A` is.
- Recomputing the whole sheet, or re-running cycle detection over the whole
  sheet, after each edit.
- Re-parsing formula text at evaluation time, or evaluating both `IF`
  branches. Only the selected branch is evaluated. Both branches still count
  as dependencies.
