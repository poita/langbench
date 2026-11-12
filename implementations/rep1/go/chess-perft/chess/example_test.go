package chess_test

import (
	"fmt"

	"github.com/example/chess-perft/chess"
)

func ExamplePerft() {
	pos := chess.StartPosition()
	for depth := 0; depth <= 3; depth++ {
		fmt.Println(depth, chess.Perft(pos, depth))
	}
	// Output:
	// 0 1
	// 1 20
	// 2 400
	// 3 8902
}

func ExampleDivide() {
	pos, err := chess.ParseFEN("8/P1k5/K7/8/8/8/8/8 w - - 0 1")
	if err != nil {
		panic(err)
	}
	for _, e := range chess.Divide(pos, 1) {
		fmt.Println(e.Move, e.Nodes)
	}
	// Output:
	// a6a5 1
	// a6b5 1
	// a7a8b 1
	// a7a8n 1
	// a7a8q 1
	// a7a8r 1
}

func ExamplePosition_Make() {
	pos := chess.StartPosition()
	for _, uci := range []string{"e2e4", "e7e5", "g1f3"} {
		m, err := pos.ParseMove(uci)
		if err != nil {
			panic(err)
		}
		next := pos.Make(m)
		pos = &next
	}
	fmt.Println(pos.FEN())
	fmt.Println(len(pos.LegalMoves()), "legal moves for", pos.SideToMove())
	// Output:
	// rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2
	// 29 legal moves for b
}
