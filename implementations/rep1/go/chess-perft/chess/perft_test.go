package chess

import (
	"fmt"
	"testing"
)

var perftCases = []struct {
	name  string
	fen   string
	nodes []uint64 // nodes[i] is perft(i+1)
}{
	{"start", StartFEN, []uint64{20, 400, 8902, 197281, 4865609}},
	{"kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
		[]uint64{48, 2039, 97862, 4085603}},
	{"position3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
		[]uint64{14, 191, 2812, 43238, 674624, 11030083}},
	{"position4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
		[]uint64{6, 264, 9467, 422333}},
	{"position5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
		[]uint64{44, 1486, 62379, 2103487}},
	{"position6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
		[]uint64{46, 2079, 89890, 3894594}},
}

func TestPerftReferenceValues(t *testing.T) {
	for _, tc := range perftCases {
		t.Run(tc.name, func(t *testing.T) {
			p, err := ParseFEN(tc.fen)
			if err != nil {
				t.Fatal(err)
			}
			for i, want := range tc.nodes {
				depth := i + 1
				if testing.Short() && want > 500000 {
					continue
				}
				if got := Perft(p, depth); got != want {
					t.Errorf("perft(%d) = %d, want %d", depth, got, want)
				}
			}
		})
	}
}

func TestPerftEdgeCases(t *testing.T) {
	tests := []struct {
		name  string
		fen   string
		depth int
		want  uint64
	}{
		{"depth zero", StartFEN, 0, 1},
		{"negative depth", StartFEN, -3, 1},
		{"stalemate", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", 1, 0},
		{"stalemate deeper", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", 4, 0},
		{"checkmate (fool's mate)", "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3", 2, 0},
		{"stalemate at depth zero", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", 0, 1},
		// The en passant capture would expose the king along the fifth rank.
		{"ep discovered check", "8/8/8/K2pP2r/8/8/8/7k w - d6 0 1", 1, 6},
		// Ep square given but no pawn can use it.
		{"unusable ep square", "4k3/8/8/8/4P3/8/8/4K3 b - e3 0 1", 1, 5},
		// Capturing the checking pawn en passant resolves check.
		{"ep captures checker", "8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1", 1, 9},
		// A pawn pinned on the diagonal may only capture its pinner.
		{"pinned pawn", "4k3/8/8/8/1b6/8/3P4/4K3 w - - 0 1", 1, 4},
		{"double check", "4k3/8/8/8/8/3n4/4r3/4K3 w - - 0 1", 1, 3},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, err := ParseFEN(tt.fen)
			if err != nil {
				t.Fatal(err)
			}
			if got := Perft(p, tt.depth); got != tt.want {
				t.Errorf("Perft(%s, %d) = %d, want %d", tt.fen, tt.depth, got, tt.want)
			}
		})
	}
}

func TestDivide(t *testing.T) {
	p, _ := ParseFEN("8/P1k5/K7/8/8/8/8/8 w - - 0 1")
	want := "a6a5=1 a6b5=1 a7a8b=1 a7a8n=1 a7a8q=1 a7a8r=1"
	var got string
	for i, e := range Divide(p, 1) {
		if i > 0 {
			got += " "
		}
		got += fmt.Sprintf("%s=%d", e.Move, e.Nodes)
	}
	if got != want {
		t.Errorf("divide = %q, want %q", got, want)
	}

	p, _ = ParseFEN("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	d := Divide(p, 2)
	var total uint64
	for i, e := range d {
		total += e.Nodes
		if i > 0 && d[i-1].Move.String() >= e.Move.String() {
			t.Errorf("divide not sorted at %s", e.Move)
		}
		if e.Move.String() == "e1c1" && e.Nodes != 23 {
			t.Errorf("e1c1 = %d, want 23", e.Nodes)
		}
	}
	if total != 568 || total != Perft(p, 2) {
		t.Errorf("divide total = %d, want 568", total)
	}

	if Divide(p, 0) != nil {
		t.Error("Divide with depth 0 should be nil")
	}
}

func BenchmarkPerftKiwipete4(b *testing.B) {
	p, _ := ParseFEN(perftCases[1].fen)
	for i := 0; i < b.N; i++ {
		Perft(p, 4)
	}
}
