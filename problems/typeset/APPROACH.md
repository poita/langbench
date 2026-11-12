# typeset: required approach

SPEC.md defines what the program does; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `I` the items in one horizontal list, `B` its breakpoints, `N` the
break nodes created (`N ≤ 4B`), `A` the pass-1 active nodes, `V` the vertical
items, `P` the output items.

## Algorithm

A layered pipeline. Load the faces (glyph advances and kerning pairs as maps)
and the Liang hyphenation patterns; parse the settings; parse the document
into a block tree with inline text resolved into styled runs. Walk the tree
once: build each horizontal list, break it with SPEC.md's total-fit
(Knuth–Plass) algorithm, set its lines and append the vertical items. Paginate
the body with SPEC.md's per-page forward scan, then build and paginate the
table of contents, then format each page's items and sort them.

## Required rules

1. **Measuring a candidate line is O(1)**, never a sum over its items (for
   example, prefix sums of width, stretch, shrink and infinite-glue count).
2. **Pass 1 prunes overfull nodes:** a node whose line to the current
   breakpoint is overfull (`W − Z > L`, excluding pre-break text) leaves the
   active set for good. **Pass 2 is not pruned:** it evaluates every node at
   every breakpoint.
3. **Each list is built and broken once**, including table cells (measured for
   `nat` and `min` and broken from the same list), figures and footnote lines.
4. **The body is paginated once, then the TOC**, with no fixed-point
   iteration.

## Complexity

Building a list is O(I). Pass 1 is O(B·A) and pass 2 O(B·N). Liang
hyphenation of a segment of length `n` is O(n · longest pattern). Break
legality is O(V) per vertical list, and each page's cut scan is linear in the
items it examines, not quadratic in the page's items. Output is O(P log P).
