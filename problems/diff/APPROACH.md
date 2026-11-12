# diff: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` and `M` are the line counts of A and B, `D` the minimum edit cost,
`L` the input size.

## Algorithm

**diff** runs Myers' algorithm in its linear-space divide-and-conquer form
(the "middle snake" variant, Myers 1986 §4b) on the two line sequences;
trimming common prefixes and suffixes is allowed. The script is produced in
order, as tags and line indices.

**patch** applies the script to A in one pass, with no diff work.

## Required rules

1. **Comparing two lines in the search is O(1)**, for example by interning
   each distinct line to an integer id first.
2. **Linear-space Myers.** No saved frontier per round with a backtrack over
   them, and no N×M LCS table or bit-parallel LCS.
3. **Exact.** The script is minimal for every input: no cost cutoffs, no
   "too expensive" heuristics, no discarding of lines unique to one file, no
   anchoring on unique lines (patience, histogram).

## Complexity

Reading, interning and output are O(L) expected. diff is O((N+M)·D) time and
O(N+M) space beyond the input and output; the recursion depth is O(log D).
patch is O(L).
