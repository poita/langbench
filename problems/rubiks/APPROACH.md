# rubiks: required approach

SPEC.md defines what the solver outputs; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `N ≤ 100` scrambles of `T ≤ 1000` tokens. Everything else is a constant
of the cube group.

## Algorithm

Thistlethwaite's four-phase algorithm, with an exact distance table per phase
and greedy descent. Each phase has a coordinate identifying the cube's coset of
the next subgroup. Once per run, each phase's distance table is filled by
breadth-first search from the goal over that coordinate space. A scramble is
applied to a solved cube; then each phase repeatedly takes an allowed move
whose successor is one step closer to the goal, until it reaches it. Each phase is optimal, so a solution has at most
7 + 10 + 13 + 15 = 45 moves.

## Required rules

1. **Phase move sets:** phase 1 all 18 moves; phase 2 without F/B quarter
   turns (14); phase 3 U/D turns plus L2 R2 F2 B2 (10); phase 4 the six half
   turns.
2. **Exactly these coordinate spaces:**
   - phase 1: orientation of 11 edges, 2,048 values;
   - phase 2: orientation of 7 corners × positions of the four E-slice edges,
     2,187 × 495 = 1,082,565 values;
   - phase 3: the corner permutation's class modulo the 96 half-turn corner
     permutations × positions of the M-slice edges among the eight U/D-layer
     edge positions, 420 × 70 = 29,400 values;
   - phase 4: the corner permutation among the 96 half-turn permutations × the
     permutation of each edge slice within its four positions, 96 × 24³ =
     1,327,104 values.
3. **Tables are built once per run** and shared by every scramble. Solving a
   scramble is only the greedy descent: no search per scramble
   (bidirectional, iterative-deepening or otherwise).

## Complexity

Building the tables is O(Σ table size × phase moves). Each scramble costs O(T)
to apply plus at most 45 descent steps of up to 18 moves each.
