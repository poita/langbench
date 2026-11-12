# chess-perft

A legal move generator for standard chess written in D, with **perft** and
**divide** queries. It is a small reusable library (`chessperft`) plus a thin
command-line tool that reads queries on stdin.

## Design

* Bitboard position with a mailbox for piece lookup; moves are applied by
  copy-make (`auto next = pos; next.play(m);`).
* Slider attacks use classical ray attacks; all attack tables are computed at
  compile time.
* The generator finds the king's checkers and pinned pieces and emits only
  legal moves. Only king moves (against the enemy attack set) and en passant
  captures are verified individually.
* At depth 1 the moves are counted, not played (bulk counting). The whole tree
  is walked; there is no hashing, caching or threading.

Source layout:

| Module | Responsibility |
|---|---|
| `chessperft.types` | colours, piece types, squares, `Move` (UCI I/O) |
| `chessperft.bitboard` | bitboard helpers, attack tables, slider attacks |
| `chessperft.position` | `Position`, FEN parsing/formatting, `play`, attack tests |
| `chessperft.movegen` | `legalMoves`, `countLegalMoves` |
| `chessperft.perft` | `perft`, `divide` |
| `chessperft.query` | the CLI's line format (`parseQuery`, `answer`) |
| `app/main.d` | the command-line tool |

## Build

Requires LDC and dub (developed with LDC 1.41.0 / dub 1.40.0).

```sh
dub build -b release --compiler=ldc2   # or ./build.sh
```

This produces the `chess-perft` executable in the project directory.

## Tests

Tests are D `unittest` blocks next to the code (move generation rules, FEN
handling, and the standard perft reference positions):

```sh
dub test --compiler=ldc2
```

## Command line

`./run.sh` (or `./chess-perft`) reads one query per line on stdin and writes
one answer per query to stdout:

```
<fen: 6 fields> <depth>            -> perft(depth), one line
<fen: 6 fields> divide <depth>     -> "<move> <count>" per legal move, sorted, then "total <n>"
```

Halfmove and fullmove fields are ignored. Moves are UCI (`e2e4`, `a7a8q`,
castling as the king move, en passant as the pawn move).

```console
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

## Library example

```d
import std.stdio;
import chessperft;

void main()
{
    auto pos = Position.fromFen(startFen);
    writeln(perft(pos, 4));                  // 197281

    foreach (e; divide(pos, 2))              // sorted by UCI text
        writefln("%s %s", e.move, e.nodes);  // a2a3 20, a2a4 20, ...

    auto list = legalMoves(pos);             // MoveList (stack allocated)
    pos.play(list[0]);                       // apply a move in place
    writeln(pos.toFen);
}
```

Use it from another dub project by adding a path dependency on this package
and `import chessperft;`.
