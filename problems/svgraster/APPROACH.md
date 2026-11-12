# svgraster: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `W`, `H` are the output size, `E` the number of polygon edges in one
paint operation, `a_k` the number of edges active at sub-scanline `k`, `S` the
number of spans and `T` the total width of the pixel rows the operation touches.

## Algorithm

Each SVG file is parsed in one pass into an element tree, with a map from `id`
to element (first wins) for `use`. A recursive walk carries the CTM and the
computed painting properties down the tree. Every shape becomes a path of
`M`/`L`/`C`/`Z` segments (SPEC.md §7). A fill flattens the path in device
space; a stroke flattens it in user space, builds the outline pieces of SPEC.md
§8.2 and transforms them to device space. Each paint operation then goes
through one **active-edge-table scanline rasteriser**, which computes coverage
within SPEC.md §8.3's tolerance (sub-scanline spans as the reference does, or
exact area) and composites into a double-precision RGBA canvas. Group opacity
renders into a fresh layer (SPEC.md §8.4).

## Required rules

1. **Flattening to SPEC.md's tolerance.** Cubics and arcs are
   subdivided to 0.01 device pixels, for example with the reference's step
   counts (§7.6); no finer tolerance.
2. **Active-edge sweep.** Edges are sorted once per operation and the sweep
   visits only sub-scanlines (or rows) with active edges, keeping the active
   set in `x` order incrementally: O(E log E + Σ a_k). No global sort of all
   crossings and no visit to every sub-scanline of the canvas.
3. **Work per operation is bounded by what it touches.** Coverage costs O(1)
   per span plus O(T) per operation, never O(W·H).

## Complexity

Parsing is linear in the file size. A paint operation costs O(E log E) for edge
setup, near-linear O(Σ a_k) for the sweep, O(S) for spans and O(T) for
compositing rows. Each layer adds O(W·H), and the output conversion is O(W·H).
