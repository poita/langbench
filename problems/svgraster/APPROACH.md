# svgraster: required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Each SVG file is read whole into memory and parsed in one pass into an element
tree. An `id` map is built once per document. A recursive walk carries the
CTM and the computed, already-parsed painting properties down the tree. Every
shape becomes a path of `M`/`L`/`C`/`Z` segments in user space. For the fill,
the path is flattened in device space. For the stroke, it is flattened in user
space, outlined into pieces, and the pieces are transformed to device space.
Each paint operation (one fill or one stroke) then goes through a single
**active-edge-table scanline rasteriser** with 64 sub-scanlines per pixel row.
That rasteriser accumulates exact span coverage into two row arrays and
composites each finished row straight into a `double` RGBA canvas. Group
opacity renders into a fresh layer that is then composited. The canvas becomes
one byte buffer, written with one write per file.

Sizes used below: `W`, `H` are the output size. `P` is the number of flattened
points of a paint operation, `E` the number of polygon edges handed to the
rasteriser, `a_k` the number of active edges at sub-scanline `k`, and `R` the
number of pixel rows the operation touches.

## Required choices

1. **Input and XML, linear in the file size.** Read each file in one call into
   one buffer. Parse it with a single forward cursor (no regular expressions,
   no repeated rescans of the document). Each element stores its stripped tag
   and an ordered list of (stripped name, unescaped value) attributes; entity
   decoding runs only on values that contain `&`. The `id` map (first element
   wins) is a hash map built in one tree walk before rendering, and each `use`
   resolves in O(1).
2. **Typed property inheritance.** Computed properties form a small record of
   typed values (each paint as none, `currentColor` or three doubles;
   opacities, width, enums for rule, cap and join, miter limit, `color`). It
   is passed down the recursion by value. An element parses only the
   properties it sets itself (style declaration first, then presentation
   attribute, as SPEC §6). Its `style` attribute is split once per element.
   A value that does not parse becomes that property's initial value at that
   element, and descendants inherit the typed result. `currentColor` stays a
   marker in the record and is resolved against the shape's own computed
   `color` when it paints, so a descendant that changes `color` recolours an
   inherited `currentColor` paint. Inherited values are never kept as strings
   and re-parsed at every shape. Lookup tables such as the 147 colour names
   are built once per process.
3. **Path model.** Path data is scanned once by a hand-written tokenizer that
   parses numbers in place from the buffer (no regex, and no substring object
   per token beyond what the float conversion needs). The scanner emits only
   `M`, `L`, `C`, `Z`. `H`/`V` become `L`. `Q`/`T` become cubics by the 2/3
   rule. `S`/`T` reflect the previous control point (for `T`, the quadratic
   control point kept from before the conversion). Arcs become cubics by
   SPEC §7.5. Shapes produce the same segment list directly.
4. **Flattening by the SPEC §7.6 subdivision rule.** Every cubic is split into
   `n = ceil(sqrt(0.75*sqrt(m)/tol))` equal steps in `t`, clamped to
   `[1, 1000]`, where `m` is computed from the control points in the space
   being flattened (SPEC §7.6). The fill flattens device-space control points
   with `tol = 0.01`. The stroke flattens user-space points with
   `tol = 0.01 / s`, where `s = sqrt(max(a²+b², c²+d²))` is the larger column
   length of the CTM; when `s <= 0` nothing is stroked. Use no adaptive
   subdivision and no other error bound:
   the number of points fixes the number of stroke pieces, and so most of the
   work.
5. **Stroke outline per SPEC §8.2, into a flat buffer.** After deduplicating
   points, emit one rectangle per segment, one join piece per joint and the
   caps. Round joins, round caps and point discs use the chord step
   `2*acos(1 - tol/r)` with the user-space `tol` of item 4 (the step is `pi`
   when `1 - tol/r <= -1`, so a radius below `tol/2` never takes `acos` out
   of its domain). The arc count is `ceil(|sweep|/step)`, clamped to
   `[1, 2000]`; full discs use `ceil(2*pi/step)` clamped to `[4, 2000]`.
   Each piece is oriented to positive signed area by computing the area and
   reversing in place. Pieces are appended to one growable point buffer with
   a piece-start index (or straight into the edge list), not allocated as
   separate containers. All pieces of one stroke are then transformed by the
   CTM in place and filled together in **one** nonzero rasteriser call.
6. **Edge setup, O(E log E).** For each non-horizontal edge, store `x` at the
   top, `dx/dy`, the direction `±1` and the inclusive range of sub-scanline
   indices `k0..k1` it crosses (`k0 = ceil(64*ytop - 0.5)`,
   `k1 = ceil(64*ybot - 0.5) - 1`), clipped to `[0, 64H-1]`. Drop edges with
   `k0 > k1`: they cross no sample, and the many tiny chords of flattened
   curves and arcs are mostly of this kind. Sort the edges once by `k0`.
7. **Active-edge sweep, O(Σ a_k) per operation.** Start at the smallest `k0`,
   process sub-scanlines in increasing order, and jump over runs with no
   active edges. At each sub-scanline, add the edges whose `k0` has been
   reached and remove those past `k1` by in-place compaction. Compute each
   active edge's `x` at `y = (k + 0.5)/64`. Keep the active list in its `x`
   order from the previous sub-scanline and restore that order with an
   insertion sort (or a library sort that is near-linear on almost-sorted
   input). The order rarely changes between sub-scanlines 1/64 px apart, so
   this is near-linear. Then walk the list once, applying the winding rule to
   produce inside spans. Never materialise the crossings of the whole
   operation for a global sort, and never visit every sub-scanline of the
   canvas.
8. **Span accumulation, O(1) per span.** Each span is clipped to `[0, W]` and
   added to two reused row arrays of length `W+2`. `cover` receives the
   fractional lengths in the first and last pixel. `delta` receives `+1` and
   `-1` marking the run of fully covered pixels between them. Also track the
   row's touched pixel range `[xlo, xhi]`. Never loop over the pixels inside a
   span.
9. **Row flush, O(touched width).** When the sweep leaves a pixel row, prefix-
   sum `delta` over `[xlo, xhi]`. The coverage is `(cover + run)/64`, clamped
   to 1. Blend `alpha = paint_opacity * coverage` into the canvas directly
   with the SPEC §8.3 source-over formula, and zero only `[xlo, xhi+1]` of the
   two arrays. No coverage row object or per-row callback allocation, no
   full-width clear or blend.
10. **Canvas and scratch memory.** The canvas is one contiguous interleaved
    RGBA array of `double` (SPEC §8.3 requires double arithmetic). The
    rasteriser's edge, active and row arrays are allocated once per document
    (or reused across documents) and cleared logically (length reset, capacity
    kept). Nothing is allocated per sub-scanline, per row or per span.
11. **Group opacity.** Only `0 < opacity < 1` creates a layer: a fresh zeroed
    `W×H` canvas. The layer records the range of rows its paints and nested
    layer composites touched, and the composite of SPEC §8.4 runs over those
    rows only, skipping pixels with zero alpha; the target canvas then widens
    its own row range by the same rows.
12. **Output, O(W·H).** Pre-size one byte buffer for the header plus
    `3·W·H` bytes, fill it by index with the SPEC §8.5 conversion, and write it
    with one call per file.

## Left to the implementer

- Container types, struct layout (array-of-structs or struct-of-arrays edges),
  naming, module structure, and whether the walk is recursive or uses an
  explicit stack.
- Whether the edge `x` is recomputed from `ytop` at each sub-scanline or
  stepped incrementally by `dxdy/64`.
- The hash map type for `id` lookup, and how attributes are looked up on an
  element (linear scan of the short list or a small map).
- The float-to-text and text-to-float conversion routines, as long as they do
  not allocate per token.
- Whether layers and edge buffers come from a pool, and whether closed
  pieces that lie entirely outside the canvas are culled before edge setup.
  Such pieces contribute zero net winding inside it, so this is safe.
- Loop-level micro-optimisations: bounds-check elimination, `int32` versus
  native indices, unrolling, special cases for two crossings.

## Pitfalls

- Clearing a scratch array in a way that drops its capacity, so the next
  append reallocates. In some languages, setting a dynamic array's length to
  zero or shrinking it by slicing has this effect. Done per sub-scanline,
  allocation and garbage collection dominate the rasteriser's run time.
- Allocating a new array per stroke piece, per transformed piece, per row of
  crossings or per sub-scanline bucket. Building a container per sub-scanline
  for the whole operation is `64·R` allocations per fill.
- Per-operation work proportional to the canvas instead of the shape:
  per-row or per-sub-scanline count or bucket arrays sized by `H` or `64·H`
  rather than by the shape's row range, loops over every row
  of the canvas, full-width zeroing or blending of each row, or a full-canvas
  pass for each paint. At 1200×1200, with hundreds of paints, this dominates.
- Generating all crossings of an operation up front and sorting them globally
  by (sub-scanline, x). That costs O(C log C) and memory for all of them,
  where the active-edge sweep needs only a near-linear re-sort.
- Sorting on every sub-scanline through a generic sort that dispatches each
  comparison or swap by reflection or an opaque, non-inlined callback, when
  the input is almost sorted and usually short.
- Looping over every pixel of a span to add coverage, instead of the
  `cover`/`delta` difference arrays.
- Rasterising each stroke piece separately. Their union must come from one
  nonzero fill, and separate fills are both wrong and slower.
- Using a tighter flattening tolerance than item 4, such as the Frobenius norm
  of the CTM, or a higher arc-segment count. More points mean more pieces,
  joins and edges.
- Keeping properties as a string dictionary that is copied for every element
  and re-parsed at every shape. Searching the tree for each `use` reference.
- Building the output by appending one byte at a time to a growing buffer, or
  writing pixel by pixel to an unbuffered file.
