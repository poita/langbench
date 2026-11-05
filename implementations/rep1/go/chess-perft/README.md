# chess-perft

A fully legal chess move generator in Go, with a `perft` / `divide` command-line
tool on top. It uses only the standard library.

- Bitboards plus a mailbox; precomputed knight, king and pawn tables.
- Sliders use classical ray lookups (nearest blocker found with a bit-scan).
  There are no magic bitboards.
- Legal moves are generated directly from the checkers, a check-evasion mask and
  pin masks, so no move is played just to test legality. King moves are tested
  with the king removed from the occupancy. En passant is tested with an
  explicit king-safety check.
- `Perft` counts the legal moves at depth 1 without playing them. Interior nodes
  use in-place `Make`/`Unmake` with a small undo record and a preallocated move
  stack. The search is single-threaded with no caching.

## Build

Requires Go 1.27.1 or newer.

```sh
./build.sh          # writes bin/chess-perft
go test ./...       # unit tests
```

`build.sh` and `run.sh` work from any directory.

## Command-line use

`run.sh` (or `bin/chess-perft`) reads queries from stdin, one per line, and
writes one result per query to stdout. A query is a six-field FEN record
followed by a depth, or by `divide` and a depth:

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

The halfmove and fullmove counters are ignored.

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

A perft query prints the leaf count. A divide query prints `<move> <count>` for
every legal root move in byte order of the UCI move string, then `total <n>`.
A position with no legal moves prints `total 0`. The tool exits with status 1
and a message on stderr if a query is malformed.

## Library

The `chessperft/chess` package:

| File | Contents |
|------|----------|
| `bitboard.go` | `Bitboard`, `Square`, `Color`, `Piece` types and bit helpers |
| `tables.go` | attack tables, `Between`, `Line`, `RookAttacks`, `BishopAttacks`, `QueenAttacks` |
| `move.go` | the 16-bit `Move`, UCI formatting, `Position.ParseMove` |
| `position.go` | `Position`, `ParseFEN`, `FEN`, attack queries |
| `makemove.go` | `Make` / `Unmake` |
| `movegen.go` | `LegalMoves`, `CountMoves` |
| `perft.go` | `Perft`, `Divide` |

```go
package main

import (
	"fmt"

	"chessperft/chess"
)

func main() {
	pos, err := chess.ParseFEN("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
	if err != nil {
		panic(err)
	}
	fmt.Println(pos.Perft(3)) // 97862

	// Play a move, then take it back.
	m, _ := pos.ParseMove("e1g1")
	undo := pos.Make(m)
	fmt.Println(pos.FEN())
	pos.Unmake(m, undo)

	// Per-move node counts, sorted by UCI string.
	for _, e := range pos.Divide(2)[:3] {
		fmt.Println(e.Move, e.Count)
	}
}
```

`ParseFEN` rejects positions that are not legal (missing or extra kings, pawns
on the first or last rank, castling rights without king and rook in place, the
side not to move in check). A `Position` is mutated in place and must not be
shared between goroutines. The halfmove and fullmove counters are kept as
parsed and never updated by `Make`.

## Project layout

```
chess/               library and its tests (*_test.go)
cmd/chess-perft/     command-line tool and its tests
build.sh, run.sh     build and run helpers
```
