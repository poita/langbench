# rubiks — Rubik's cube solver

Read a list of scrambles applied to a solved 3x3x3 Rubik's cube and print,
for each one, a sequence of moves that returns the cube to the solved state.
Solutions need not be optimal, but each must use at most **52 moves** in the
half-turn metric (every token `X`, `X'` and `X2` counts as one move).
Thistlethwaite's four-phase algorithm with an optimal search in each phase
always finishes within 7 + 10 + 13 + 15 = 45 moves and is the intended
approach; Kociemba's two-phase algorithm or any other method
that stays within 52 is equally acceptable.

## Cube model

The cube has six faces, named by the direction they point in when you hold
the cube: `U` (up), `D` (down), `L` (left), `R` (right), `F` (front) and `B`
(back). The centre sticker of each face never moves, so a face is
identified by its centre. The cube is **solved** when every face shows a
single colour, i.e. every sticker matches the centre of the face it is on.

Each face carries nine stickers ("facelets"), numbered 1-9 in reading order
as seen when looking straight at that face from outside the cube. The
unfolded cube below fixes the orientation of every face: `U` is above `F`
and `D` is below it, `L`, `F`, `R`, `B` form a strip in that order, and `B`
is drawn as seen from behind the cube.

```
             +----------+
             | U1 U2 U3 |
             | U4 U5 U6 |
             | U7 U8 U9 |
  +----------+----------+----------+----------+
  | L1 L2 L3 | F1 F2 F3 | R1 R2 R3 | B1 B2 B3 |
  | L4 L5 L6 | F4 F5 F6 | R4 R5 R6 | B4 B5 B6 |
  | L7 L8 L9 | F7 F8 F9 | R7 R8 R9 | B7 B8 B9 |
  +----------+----------+----------+----------+
             | D1 D2 D3 |
             | D4 D5 D6 |
             | D7 D8 D9 |
             +----------+
```

Adjacencies implied by this net (useful for building a model): `U7 U8 U9`
touch `F1 F2 F3`; `U1 U2 U3` touch `B3 B2 B1`; `U1 U4 U7` touch `L1 L2 L3`;
`U3 U6 U9` touch `R3 R2 R1`; `D1 D2 D3` touch `F7 F8 F9`; `D7 D8 D9` touch
`B9 B8 B7`; `D1 D4 D7` touch `L9 L8 L7`; `D3 D6 D9` touch `R7 R8 R9`;
`L3 L6 L9` touch `F1 F4 F7`; `F3 F6 F9` touch `R1 R4 R7`; `R3 R6 R9` touch
`B1 B4 B7`; `B3 B6 B9` touch `L1 L4 L7`.

The eight corner cubies therefore carry the facelet triples `(U9 R1 F3)`,
`(U7 F1 L3)`, `(U1 L1 B3)`, `(U3 B1 R3)`, `(D3 F9 R7)`, `(D1 L9 F7)`,
`(D7 B9 L7)`, `(D9 R9 B7)` and the twelve edge cubies the pairs `(U6 R2)`,
`(U8 F2)`, `(U4 L2)`, `(U2 B2)`, `(D6 R8)`, `(D2 F8)`, `(D4 L8)`, `(D8 B8)`,
`(F6 R4)`, `(F4 L6)`, `(B6 L4)`, `(B4 R6)`.

### Moves

A basic move turns one face a quarter turn **clockwise as seen by someone
looking directly at that face from outside the cube**. Each move is defined
below as a set of disjoint 4-cycles of facelets. A cycle `(a b c d)` means:
the sticker at `a` moves to `b`, the sticker at `b` moves to `c`, `c` moves
to `d`, and `d` moves to `a`. Stickers not mentioned stay where they are.

```
U: (U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)
D: (D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)
R: (R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)
L: (L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)
F: (F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)
B: (B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)
```

For example, after `U` on a solved cube, facelets `F1 F2 F3` show the colour
of the `R` centre (the sticker that was at `R1` is now at `F1`, and so on),
`L1 L2 L3` show the `F` colour, `B1 B2 B3` the `L` colour and `R1 R2 R3` the
`B` colour.

The eighteen move tokens are:

- `X` — one clockwise quarter turn of face `X` (the cycles above);
- `X'` — one counter-clockwise quarter turn, i.e. the inverse of `X`
  (equivalently `X` applied three times);
- `X2` — a half turn, i.e. `X` applied twice;

where `X` is one of `U D L R F B`. Every scramble and every solution is a
sequence of such tokens applied left to right, starting from the state the
cube is in.

Sanity checks for an implementation of this model: `X` applied four times is
the identity; `R U R' U'` applied six times is the identity; for any two
adjacent faces the pair (e.g. `R U`) has order 105 and for opposite faces
(e.g. `U D`) order 4; the sequence
`U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2` produces the
"superflip" (every corner solved, every edge in place but flipped).

## Input

Standard input is UTF-8 text containing `N` lines, `1 <= N <= 1000000`. Each
line is one scramble: zero or more move tokens from the eighteen listed
above, separated by single spaces, with no leading or trailing spaces. An
empty line is a scramble of zero moves (the cube is already solved). A
scramble has at most 1000 tokens. Lines end with `\n` (never `\r\n`); the
final line may or may not have a terminating newline, so `R\n` and `R` are
both a single scramble, while `R\n\n` is two scrambles (the second empty).
The input is never completely empty. Tokens are case-sensitive and are
exactly the eighteen strings listed above (`R2'`, `r` and `R'2` never occur).

Every scramble is applied to a freshly solved cube; scrambles are
independent of each other.

## Output

Print exactly `N` lines, the `i`-th line being a solution for the `i`-th
scramble: a sequence of move tokens separated by single spaces such that
applying the scramble and then the solution to a solved cube yields a solved
cube. A solution with zero moves is printed as an empty line. Each line ends
with `\n`.

Rules for a solution line:

- only the eighteen tokens `U D L R F B U' D' L' R' F' B' U2 D2 L2 R2 F2 B2`
  may appear (case-sensitive; the ASCII apostrophe `'` is the only prime);
- tokens are separated by exactly one space and the line has no leading
  space (trailing whitespace on a line is tolerated);
- the number of tokens is at most 52;
- the line may contain redundant moves (e.g. `R R'`) as long as the total
  stays within 52 — there is no requirement of optimality.

Any solution that satisfies these rules is accepted; there is no canonical
answer. Exit with status 0.

## Examples

Input:

```
R
```

One valid output (`R R R` would also be accepted):

```
R'
```

Input (three scrambles; the second is empty and the third is six repetitions
of `R U R' U'`, which returns the cube to solved):

```
F R U'

R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'
```

One valid output (`U R' F'` would also be accepted for the first line):

```
R' U2 F' L' U L U2


```

Input (the superflip):

```
U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2
```

One valid output (28 moves, produced by a Thistlethwaite solver):

```
F U D B R' L' F' L' R' D2 R' D' U' L' D' B2 F2 U F2 U R2 F2 U2 L2 U2 R2 B2 U2
```

## Performance

The largest test contains 25 scrambles of 25 random moves each; one test
has a single scramble of 1000 moves. Scrambled states are uniformly hard
(a random 25-move scramble is effectively a random cube state), so an
implementation needs pruning tables or an equivalent search strategy in
each phase, not naive search. The reference Python implementation
(Thistlethwaite, bidirectional BFS per phase with the solved-side search
cached across scrambles) solves a random state in about 0.1-0.9 s, so a
compiled implementation should finish every test in well under a second.
Suggested timeout: 30 s per test.
