# regex: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `P` is the pattern length, `G ≤ 50` the number of groups, `n ≤ 10000`
the subject length.

## Algorithm

A backtracking matcher that follows section 3 of SPEC.md. Each pattern is
parsed once, by recursive descent, into a syntax tree, and that tree (or a
program compiled from it) is matched against each of the pattern's subjects.
Character classes become character sets at parse time.

## Required rules

1. **Backtracking, leftmost-first.** Choices are explored depth-first in
   SPEC.md's order. No DFA or NFA simulation, no memoisation of (position,
   state) pairs, and no reordering of the alternatives tried.
2. **Captures follow the successful path:** a failed alternative's capture
   writes are undone, at a cost proportional to those writes rather than O(G)
   per choice.
3. **Start positions are tried in order.** A pattern that can only match at the
   start is tried only there, and starts whose character cannot begin a match
   (the set of possible first characters, computed once per pattern) are
   skipped. No other search acceleration, such as literal prefilters.

## Complexity

Parsing is O(P) per pattern. Backtracking is exponential in the worst case; the
tests keep it to a few million steps per file, so a run is linear in the input
plus the steps taken. Backtracking can nest a few choices deep per subject
character (`.*` over 10,000 characters), which the matcher must handle.
