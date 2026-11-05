package chess_test

import (
	"fmt"
	"sort"
	"testing"

	"chessperft/chess"
)

// Well-known perft values.
var perftCases = []struct {
	name, fen string
	counts    []uint64 // counts[d] = perft(d)
}{
	{"start", chess.StartFEN, []uint64{1, 20, 400, 8902, 197281}},
	{"kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", []uint64{1, 48, 2039, 97862}},
	{"position3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", []uint64{1, 14, 191, 2812, 43238, 674624}},
	{"position4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", []uint64{1, 6, 264, 9467, 422333}},
	{"position4 mirrored", "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1", []uint64{1, 6, 264, 9467, 422333}},
	{"position5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", []uint64{1, 44, 1486, 62379, 2103487}},
	{"position6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", []uint64{1, 46, 2079, 89890}},
	{"ep pin on rank", "8/8/8/K2pP2r/8/8/8/4k3 w - d6 0 1", []uint64{1, 6}},
	{"stalemate", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", []uint64{1, 0, 0, 0}},
	{"checkmate", "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", []uint64{1, 0, 0}},
}

func TestPerft(t *testing.T) {
	for _, c := range perftCases {
		t.Run(c.name, func(t *testing.T) {
			p := mustParse(t, c.fen)
			for d, want := range c.counts {
				if got := p.Perft(d); got != want {
					t.Errorf("perft(%d) = %d, want %d", d, got, want)
				}
			}
			if p.FEN() != mustParse(t, c.fen).FEN() {
				t.Error("Perft changed the position")
			}
		})
	}
}

func TestPerftNegativeDepth(t *testing.T) {
	if got := chess.NewPosition().Perft(-1); got != 1 {
		t.Errorf("perft(-1) = %d, want 1", got)
	}
}

func TestDivide(t *testing.T) {
	p := mustParse(t, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	d := p.Divide(2)
	var total uint64
	var names []string
	for _, e := range d {
		total += e.Count
		names = append(names, e.Move.String())
	}
	if total != 568 || len(d) != 26 {
		t.Errorf("divide(2): total %d over %d moves, want 568 over 26", total, len(d))
	}
	if !sort.StringsAreSorted(names) {
		t.Errorf("divide output not sorted: %v", names)
	}
	if d[0].Move.String() != "a1a2" || d[0].Count != 25 {
		t.Errorf("first entry = %v %d", d[0].Move, d[0].Count)
	}

	for _, e := range p.Divide(1) {
		if e.Count != 1 {
			t.Errorf("divide(1) %v = %d, want 1", e.Move, e.Count)
		}
	}
	if p.Divide(0) != nil {
		t.Error("Divide(0) should be nil")
	}
	if got := mustParse(t, "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").Divide(3); len(got) != 0 {
		t.Errorf("stalemate divide = %v", got)
	}
}

func TestDivideSumsToPerft(t *testing.T) {
	for _, c := range perftCases[:4] {
		p := mustParse(t, c.fen)
		var sum uint64
		for _, e := range p.Divide(3) {
			sum += e.Count
		}
		if want := p.Perft(3); sum != want {
			t.Errorf("%s: divide sums to %d, perft is %d", c.name, sum, want)
		}
	}
}

func ExamplePosition_Perft() {
	p, _ := chess.ParseFEN(chess.StartFEN)
	fmt.Println(p.Perft(3))
	// Output: 8902
}

func ExamplePosition_Divide() {
	p, _ := chess.ParseFEN("8/P1k5/K7/8/8/8/8/8 w - - 0 1")
	for _, e := range p.Divide(1) {
		fmt.Println(e.Move, e.Count)
	}
	// Output:
	// a6a5 1
	// a6b5 1
	// a7a8b 1
	// a7a8n 1
	// a7a8q 1
	// a7a8r 1
}
