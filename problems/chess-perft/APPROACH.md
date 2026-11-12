# chess-perft: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `L` is a query's leaf count (up to about 16 million per query and 20
million per file), `I` the number of non-leaf nodes of its tree.

## Algorithm

A depth-first perft over a legal move generator. Each query's FEN is parsed
into a position; the search generates a node's legal moves and, for each, plays
it and searches the child to one less depth. The generator finds the king's
checkers and the pieces pinned to it, and uses them to produce legal moves. A
divide query runs the same search under each root move.

## Required rules

1. **Bulk counting.** At depth 1 the count is the number of legal moves,
   generated but not played. The generator must therefore produce exactly the
   legal moves.
2. **Legality from checks and pins.** Ordinary moves are made legal by the
   check and pin information. Only king moves, en passant captures and moves
   while in check may be tested by playing them and checking whether the king
   is attacked.
3. **Walk the whole tree.** No transposition table, memoisation of subtree
   counts or other caching, and no parallel search.

## Complexity

Generating a node's moves is O(1) on a fixed-size board (bounded by the pieces
and their rays). A query is O(I): leaves are counted, never visited, so the run
is well below O(L). Divide adds a sort of at most a few hundred root moves.
