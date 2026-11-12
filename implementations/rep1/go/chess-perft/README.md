# chess-perft

A legal move generator for standard chess in Go, with a command-line tool that
answers **perft** and **divide** queries. The library has no dependencies
outside the Go standard library.

- Bitboard position representation, copy-make (no unmake).
- Legal move generation from checkers and pins: ordinary moves are legal by
  construction; only king moves, en passant captures and castling are tested
  explicitly.
- Bulk counting at depth 1 (moves are generated and counted, not played).
- The whole tree is walked: no transposition table, no caching, no parallelism.

## Layout

```
chess/              the library (package chess)
  bitboard.go         Bitboard and Square
  piece.go            Color, PieceType, Piece
  move.go             Move and its UCI text form
  tables.go           attack/ray/between/line tables, slider attacks
  position.go         Position and accessors, attack queries
  fen.go              FEN parsing and formatting
  movegen.go          legal move generation
  makemove.go         playing a move
  perft.go            Perft and Divide
cmd/chess-perft/    the command-line tool
build.sh, run.sh    build and run scripts
```

## Build

Requires Go 1.27.1 or newer.

```
./build.sh          # writes bin/chess-perft
go test ./...       # run the tests (add -short to skip the slowest perfts)
```

## Command-line use

`chess-perft` reads queries from stdin, one per line, and writes one result per
query to stdout (`./run.sh` runs the built binary from any directory).

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

The first six fields are a FEN record (the move counters are ignored). A perft
query prints the number of leaf nodes at that depth. A divide query prints
`<move> <count>` for each legal move, sorted by move text, then `total <n>`.
Moves are in UCI notation (`e2e4`, `e1g1` for castling, `a7a8q` for promotion).
Malformed input is reported on stderr with exit status 1.

```
$ printf 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3\n8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n' | ./run.sh
8902
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

## Library use

```go
package main

import (
	"fmt"

	"github.com/example/chess-perft/chess"
)

func main() {
	pos, err := chess.ParseFEN("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
	if err != nil {
		panic(err)
	}
	fmt.Println(chess.Perft(pos, 3)) // 97862

	m, _ := pos.ParseMove("e1g1") // castle kingside
	next := pos.Make(m)           // pos itself is unchanged
	fmt.Println(next.FEN(), len(next.LegalMoves()))

	for _, e := range chess.Divide(&next, 2)[:3] {
		fmt.Println(e.Move, e.Nodes)
	}
}
```

Main entry points: `ParseFEN`, `StartPosition`, `Position.LegalMoves`,
`Position.Make`, `Position.ParseMove`, `Position.InCheck`, `Position.FEN`,
`Perft`, `Divide`, plus the attack functions `RookAttacks`, `BishopAttacks`,
`QueenAttacks`, `KnightAttacks`, `KingAttacks` and `PawnAttacks`. See
`go doc ./chess`.

## Testing

Besides the well-known perft reference positions and unit tests for FEN, moves,
castling and en passant, the test suite cross-checks the generator against an
independent naive generator (`chess/naive_test.go`) over many random games.
