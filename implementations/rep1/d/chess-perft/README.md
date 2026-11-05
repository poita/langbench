# chess-perft

A legal chess move generator in D, with **perft** and **divide** node counting,
plus a small command-line tool that answers queries read from stdin.

* Bitboard position with a mailbox, built from precomputed (compile-time) attack tables.
* Classical ray attacks for sliders: no magic bitboards, no PEXT.
* Fully legal generation using checkers, an evasion mask and pin masks, so no move
  is played just to test legality; the depth-1 count is the number of legal moves
  (bulk counting, without even materialising them).
* In-place make/unmake with a tiny undo record.
* Single-threaded, no hashing. Standard library only.

Requires LDC (developed with 1.41.0) and dub (1.40.0).

## Build

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces the `chess-perft` executable in the project directory.

## Test

```sh
dub test --compiler=ldc2
```

The unit tests live in `tests/`, separate from the library in `source/chessperft/`.

## Command-line use

`./run.sh` (or `./chess-perft` directly) reads queries from stdin, one per line,
and writes one answer per query to stdout. A query is a FEN record followed by a
depth, or by the word `divide` and a depth:

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

The halfmove and fullmove fields are ignored. A perft query prints one number. A
divide query prints `<move> <count>` for every legal root move (UCI notation, sorted
by byte order) followed by `total <n>`.

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

The exit status is 0 on success; malformed input is reported on stderr with status 1.

## Library use

The library is the `chessperft` package under `source/`. Modules:

| Module | Responsibility |
|---|---|
| `chessperft.bitboard` | `Bitboard` type, bit-scan/popcount helpers, file/rank masks |
| `chessperft.types` | `Color`, `PieceType`, packed `Piece`, castling bits, square names |
| `chessperft.tables` | compile-time attack tables, rays, `between`/`line`, slider attacks |
| `chessperft.move` | 16-bit `Move`, `MoveFlag`, UCI formatting |
| `chessperft.position` | `Position`: FEN in/out, `makeMove`/`unmakeMove`, attack queries |
| `chessperft.movegen` | `generateLegal`, `countLegal`, `legalMoves` |
| `chessperft.perft` | `perft`, `divide` |
| `chessperft.query` | the query-line protocol used by the CLI |

`import chessperft;` pulls in everything.

```d
import std.stdio : writeln;
import chessperft;

void main()
{
    // Kiwipete
    auto pos = Position.fromFen(
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");

    writeln(perft(pos, 3));                  // 97862

    foreach (e; divide(pos, 2).entries)      // per-root-move counts, sorted
        writeln(e.move, " ", e.count);

    // Walk the tree yourself.
    foreach (m; legalMoves(pos))
    {
        auto undo = pos.makeMove(m);
        // ... inspect pos ...
        pos.unmakeMove(m, undo);
    }
}
```

To use it from another dub project, depend on this package and select the
`library` configuration:

```json
"dependencies": { "chess-perft": { "path": "../chess-perft" } },
"subConfigurations": { "chess-perft": "library" }
```

`Position.fromFen` throws `FenException` on malformed text. The halfmove and fullmove
fields are optional and ignored: there is no fifty-move, repetition or
insufficient-material rule.

## Layout

```
dub.json            manifest (configurations: cli, library, unittest)
build.sh run.sh     build and run wrappers
app/main.d          the CLI
source/chessperft/  the library
tests/              unit tests (run by `dub test`)
```
