# spreadsheet: required approach

SPEC.md defines what the engine outputs; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `L` the length of one formula, `C` the cells in the sheet, `A` the
affected set of one edit (the edited cell plus every cell that transitively
reads it) and `E_A` the number of dependency edges out of `A`'s cells, a range
counting one edge per covered cell.

## Algorithm

A dependency graph with incremental recalculation. A `set` parses its formula
once, by recursive descent, into a syntax tree with resolved references, and
records its dependencies (ranges expanded) both as edges from the cell and as
reverse edges on the cells it reads. After each `set` or `clear`, a traversal
of the reverse edges from the edited cell finds `A`; Tarjan's
strongly-connected-components algorithm over the subgraph induced by `A` emits
components dependencies-first. A cyclic component (more than one cell, or a
cell that reads itself) gets `#CYCLE!`; any other cell is evaluated as soon as
its component is emitted. `dump` sorts the non-empty cells into row-major
order.

## Required rules

1. **Recalculation is eager and incremental.** Each edit visits only `A`: no
   whole-sheet recalculation, cycle detection or per-edit work proportional to
   the sheet's size.
2. **Evaluation reads stored values.** A reference or range reads the current
   value of the cells it names and never evaluates them on demand.
3. **Formulas are never re-parsed.** Evaluation walks the syntax tree built at
   `set` time.

## Complexity

A `set` is O(L + range cells) to parse and record dependencies. Recalculation
is O(|A| + E_A) plus the cost of evaluating `A`'s formulas, each linear in its
syntax tree and range cells. `get` is O(1) expected; `dump` is O(C log C).
Dependency chains are up to 10,000 cells long, which the graph traversals must
handle; a formula's syntax tree is a few hundred levels deep at most.
