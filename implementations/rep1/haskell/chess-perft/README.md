# chess-perft

A legal move generator for standard chess, with **perft** and **divide**
counting, written in Haskell using only GHC's bundled libraries (`base` and
`array`; tests use `hspec` and `QuickCheck`).

* A reusable library (`Chess.Perft.*`) with FEN parsing, a bitboard position,
  a legal move generator and the perft/divide search.
* A thin command-line tool, `chess-perft`, that answers line-oriented queries.

## How it works

Positions are bitboards (one `Word64` per piece type plus one per colour).
Slider attacks use precomputed rays with first-blocker lookup.

For each node the generator finds the king's checkers and the pieces pinned
to it, and uses them to emit only legal moves: with two checkers only king
moves exist; with one, other pieces are confined to capturing the checker or
blocking; pinned pieces are confined to their pin line. King moves are checked
against enemy attacks (with the king lifted off the board), and castling
checks the crossed squares. Only en passant captures are verified by playing
them (to catch the horizontal discovered check).

Perft walks the whole tree depth-first (no hashing, no parallelism); at depth
1 it counts the generated moves instead of playing them.

## Build

Requires GHC 9.14 and cabal 3.18.

```
./build.sh            # builds and copies the executable to bin/chess-perft
cabal build           # library + executable, the usual way
cabal test            # test suite (hspec + QuickCheck)
```

## Command-line usage

`./run.sh` (or `bin/chess-perft`) reads queries on stdin, one per line, and
writes results to stdout. A query is a six-field FEN (the halfmove and
fullmove fields are required but ignored) followed by a depth, optionally
preceded by `divide`:

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

```
$ printf '%s\n' \
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3' \
    '8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1' | ./run.sh
8902
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

A perft query prints `perft(depth)`. A divide query prints one
`<move> <count>` line per legal move (UCI notation, sorted by ASCII order),
where `count` is `perft(depth - 1)` after that move, followed by
`total <n>`. A position without legal moves prints just `total 0`. A malformed
line makes the tool print a message to stderr and exit non-zero.

## Library usage

```haskell
import Chess.Perft

main :: IO ()
main = do
  case parseFen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" of
    Left err  -> putStrLn err
    Right pos -> do
      print (perft 4 pos)                       -- 197281
      print (map moveToUci (legalMoves pos))     -- the 20 opening moves
      let pos' = makeMove pos (head (legalMoves pos))
      putStrLn (toFen pos')
      mapM_ (\(m, n) -> putStrLn (moveToUci m ++ " " ++ show n)) (divide 2 pos)
```

### Modules

| Module | Responsibility |
|---|---|
| `Chess.Perft.Types` | colours, pieces, squares, castling rights, packed `Move`, UCI notation |
| `Chess.Perft.Bitboard` | `Bitboard`, bit iteration, attack tables, `between`/`line` |
| `Chess.Perft.Position` | `Position`, FEN parse/print, `makeMove`, attack and check queries |
| `Chess.Perft.MoveGen` | `legalMoves`, `countLegalMoves` |
| `Chess.Perft.Search` | `perft`, `divide` |
| `Chess.Perft.Query` | the CLI's query parser and output formatter |
| `Chess.Perft` | re-exports the above (except `Bitboard`) |

Notes: `makeMove` assumes the move is legal in the position (e.g. taken from
`legalMoves`). `parseFen` drops castling rights and en passant squares that
are inconsistent with the board, and rejects positions with the wrong number
of kings, pawns on the first/last rank, or the side not to move in check.

## Tests

`cabal test` runs: FEN round trips and `makeMove` behaviour; hand-made
positions for pins, checks, castling, en passant and promotion; the published
perft reference values; and QuickCheck properties over random game walks
(the bulk move count equals the length of the generated list, no legal move
leaves the king attacked, and the generator agrees with an independent naive
generator that filters pseudo-legal moves by playing them).
