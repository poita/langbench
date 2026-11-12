# depresolve: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `P ≤ 3000` packages, `V ≤ 1600` versions of one package, `R` the total
number of requirements, `S` the number of search steps (a few million at most).

## Algorithm

Parse the input in one pass. Each range becomes a half-open interval of
versions `[lo, hi)`, each package's versions are sorted newest first, and each
requirement's interval becomes the contiguous range of indices it admits in
that order, found by binary search once after parsing.

The search is SPEC.md's depth-first, newest-first, chronologically
backtracking procedure over choice points, each holding its package, its
remaining candidates and the pending requirements it continues with. On
success the chosen packages are sorted by name and printed.

## Required rules

1. **SPEC.md's search exactly.** No other search strategy: no backjumping,
   conflict learning, reordering of requirements or candidates, or pruning.
2. **A search step is O(1) plus the requirements it adds.** Neither the chosen
   versions nor the pending requirements are copied or rebuilt at a choice
   point; for example, choices are undone through a trail and the pending
   requirements are a list shared between choice points.
3. **Candidates are the precomputed index range**: no scan of a package's
   versions to filter candidates during the search.

## Complexity

Parsing and preprocessing are O(input + R log V) plus sorting each package's
versions. The search is O(S + requirements pushed). Its depth reaches about
10,000 pending requirements, which the program must handle.
