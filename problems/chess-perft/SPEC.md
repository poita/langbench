# Chess legal move generator with perft

Implement a complete legal move generator for standard chess and use it to
answer **perft** and **divide** queries read from stdin.

`perft(depth)` is the number of leaf nodes reached by playing every sequence of
`depth` legal moves from a position (each sequence counted once; no
deduplication of transpositions). `perft(0) = 1`, and `perft(1)` is simply the
number of legal moves in the position.

## Input

Zero or more lines, each a single query. Fields are separated by exactly one
ASCII space; there is no leading or trailing whitespace and no blank lines.
Lines end with `\n` (never `\r\n`); a trailing newline after the last line
is optional. Input is ASCII. Input is always well-formed as described below,
so no error handling or validation is required. If there are no queries the
output is empty.

Each line is one of:

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

The first six fields are a standard FEN record:

- `<placement>`: eight rank strings separated by `/`, rank 8 first, each rank
  described file a to h; digits `1`-`8` count consecutive empty squares;
  letters `PNBRQK` are white pieces and `pnbrqk` black pieces.
- `<side>`: `w` or `b`, the side to move.
- `<castling>`: `-` or a non-empty subset of `KQkq` in that order (`K`/`Q` =
  white kingside/queenside, `k`/`q` = black).
- `<ep>`: `-` or an en passant target square such as `e3` or `d6`.
- `<halfmove>` and `<fullmove>`: non-negative integers. They are present but
  **must be ignored**: there is no fifty-move rule, no repetition rule and no
  insufficient-material rule in this problem.

`<depth>` is a decimal integer. For a perft query `0 <= depth <= 7`; for a
divide query `1 <= depth <= 7`. (Test data never exceeds the sizes given under
Input sizes.)

Every position is a legal chess position: exactly one king per side, no pawns on
rank 1 or 8, the side *not* to move is not in check. Castling rights are only
given when the corresponding king is on its home square (e1/e8) and the rook is
on its home corner (h1/a1/h8/a8). The `<ep>` square, when present, is always the
square directly behind an enemy pawn that has just advanced two squares (rank 3
if black is to move, rank 6 if white is to move), and that square is empty. It
may be present even when no pawn of the side to move can capture on it; such a
square simply yields no move.

## Output

One result per query, in input order, each line terminated by `\n`. Every
count in the tests is below 2^31, so a signed 32-bit integer suffices (a
64-bit integer is of course fine).

- A perft query outputs a single line containing `perft(depth)` as a decimal
  integer with no leading zeros, sign, or separators.
- A divide query outputs one line `<move> <count>` for **every** legal move in
  the position, where `<count>` is `perft(depth - 1)` of the position after
  that move (so with `depth` 1 every count is `1`). These lines are sorted in
  ascending lexicographic (ASCII byte) order of the `<move>` string. After
  them comes exactly one line `total <n>` where `<n>` is the sum of the
  counts (equal to `perft(depth)`). If the position has no legal moves the
  output for that query is just `total 0`.

`<move>` uses UCI long algebraic notation: origin square, destination square,
and for a pawn promotion a fifth character giving the promotion piece in
lowercase (`q`, `r`, `b`, `n`). Squares are a lowercase file letter `a`-`h`
followed by a rank digit `1`-`8`. Castling is written as the king's move
(`e1g1`, `e1c1`, `e8g8`, `e8c8`). An en passant capture is written as the
capturing pawn's origin and destination (e.g. `e5d6`). No check or mate
suffixes, no capture markers.

## Rules of move legality

Standard FIDE chess rules apply. A move is legal iff it is a pseudo-legal
move of the side to move after which that side's king is not attacked.

- **Pawns** move one square forward to an empty square; from their starting
  rank (2 for white, 7 for black) they may instead move two squares forward if
  both squares are empty. They capture one square diagonally forward. A pawn
  reaching the last rank (by move or capture) **must** promote to a queen,
  rook, bishop or knight; each promotion choice is a distinct move, so a pawn
  push to the last rank produces four moves (`a7a8q`, `a7a8r`, `a7a8b`,
  `a7a8n`).
- **En passant**: a pawn on its fifth rank whose diagonally-forward square is
  the `<ep>` square may capture there, removing the enemy pawn that sits
  directly beside it (on the same rank as the capturing pawn). The capture is
  subject to the usual legality test: the mover's king must not be attacked
  afterwards, including along the rank vacated by *both* pawns. The en passant
  right exists only on the move immediately following a two-square pawn
  advance; after any other move the ep square is cleared.
- **Knights, bishops, rooks, queens, kings** move as usual; sliders stop at
  the first occupied square, capturing it if it is an enemy piece.
- **Castling** (kingside `e1g1`/`e8g8`, queenside `e1c1`/`e8c8`) is legal iff:
  the side still has the corresponding right; the squares between king and
  rook are empty (f1,g1 / b1,c1,d1 and the equivalents on rank 8); the king
  is not currently in check; and neither the square the king crosses (f1 or
  d1) nor the square it lands on (g1 or c1) is attacked by the opponent. The
  b1/b8 square may be attacked; the rook may be attacked. Castling moves both
  the king and the rook.
- **Castling rights are lost**: both of a side's rights when its king moves
  (including by castling); the kingside right when the h-rook moves or is
  captured on its home square; the queenside right when the a-rook moves or is
  captured on its home square. A promotion capture on a corner square also
  removes the right (the rook was captured). A right once lost is never
  regained: if a rook is captured on its corner and another rook later
  recaptures there, the side still may not castle on that wing.
- **Check, checkmate, stalemate**: a position where the side to move has no
  legal move (checkmate or stalemate) contributes no further nodes:
  `perft(d) = 0` for `d >= 1`. Double check allows only king moves. A king may
  not move to a square attacked by the opponent, including squares "behind"
  it along a checking slider's line.

## Examples

Input:
```
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3
r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0
```
Output:
```
20
8902
1
```

Input:
```
8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1
```
Output (the pawn has four promotions; the king on a6 may only go to a5 or b5
because the black king guards b6 and b7):
```
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

Input:
```
r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2
7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3
```
Output (the second position is stalemate):
```
a1a2 25
a1a3 24
a1a4 23
a1a5 22
a1a6 21
a1a7 17
a1a8 3
a1b1 26
a1c1 25
a1d1 23
e1c1 23
e1d1 26
e1d2 26
e1e2 26
e1f1 26
e1f2 26
e1g1 23
h1f1 23
h1g1 25
h1h2 25
h1h3 24
h1h4 23
h1h5 22
h1h6 21
h1h7 17
h1h8 3
total 568
total 0
```

## Reference values

Well-known perft numbers (all included in the tests):

| Position | d1 | d2 | d3 | d4 | d5 |
|---|---|---|---|---|---|
| start position | 20 | 400 | 8902 | 197281 | 4865609 |
| `r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1` (Kiwipete) | 48 | 2039 | 97862 | 4085603 | |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 14 | 191 | 2812 | 43238 | 674624 |
| `r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1` | 6 | 264 | 9467 | 422333 | 15833292 |
| `rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8` | 44 | 1486 | 62379 | 2103487 | |
| `r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10` | 46 | 2079 | 89890 | 3894594 | |

The third position at depth 6 is 11030083 (also in the tests).

## Input sizes

Test files contain between 1 and 160 queries. The largest single query
has roughly 16 million leaf nodes (`perft` 5 of the fourth position above; the
third position at depth 6 has about 11 million), and no test file exceeds
about 20 million leaf nodes in total. Depths go up to 7 in the tests (depth
7 only on a position with three pieces).

Counting leaves by generating (not playing) the moves at depth 1 is permitted
and expected.
