package chess

import (
	"math/rand"
	"slices"
	"testing"
)

// checkConsistency verifies that the redundant board representations agree.
func checkConsistency(t *testing.T, p *Position) {
	t.Helper()
	var occ [2]Bitboard
	for s := Square(0); s < 64; s++ {
		pc := p.board[s]
		if pc == NoPiece {
			continue
		}
		occ[pc.Color()] |= s.Bit()
		if !p.bb[pc.Color()][pc.Type()].Has(s) {
			t.Fatalf("board/bitboard mismatch at %s in %s", s, p.FEN())
		}
	}
	if occ != p.occ {
		t.Fatalf("occupancy mismatch in %s", p.FEN())
	}
	var n int
	for c := range p.bb {
		for ty := range p.bb[c] {
			n += p.bb[c][ty].Count()
		}
	}
	if n != (occ[0] | occ[1]).Count() {
		t.Fatalf("overlapping piece bitboards in %s", p.FEN())
	}
	if _, err := ParseFEN(p.FEN()); err != nil {
		t.Fatalf("Make produced an invalid position %s: %v", p.FEN(), err)
	}
}

// TestGeneratorMatchesNaive plays random games from several positions and
// compares the legal moves with the naive reference generator at every ply.
func TestGeneratorMatchesNaive(t *testing.T) {
	games, plies := 200, 120
	if testing.Short() {
		games = 40
	}
	rng := rand.New(rand.NewSource(1))
	for _, tc := range perftCases {
		for g := 0; g < games; g++ {
			p, _ := ParseFEN(tc.fen)
			for ply := 0; ply < plies; ply++ {
				got, want := sortedMoves(p.LegalMoves()), sortedMoves(naiveMoves(p))
				if !slices.Equal(got, want) {
					t.Fatalf("%s: move mismatch\n got  %v\n want %v", p.FEN(), got, want)
				}
				if len(got) == 0 {
					break
				}
				next := p.Make(got[rng.Intn(len(got))])
				p = &next
				checkConsistency(t, p)
			}
		}
	}
}

func TestMakeMove(t *testing.T) {
	tests := []struct {
		name, fen, move, want string
	}{
		{"double push sets ep", StartFEN, "e2e4",
			"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"},
		{"ep cleared", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", "g8f6",
			"rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2"},
		{"en passant", "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6",
			"4k3/8/3P4/8/8/8/8/4K3 b - - 0 1"},
		{"white kingside castle", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1",
			"r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1"},
		{"black queenside castle", "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", "e8c8",
			"2kr3r/8/8/8/8/8/8/R3K2R w KQ - 1 2"},
		{"rook move loses one right", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "h1h5",
			"r3k2r/8/8/7R/8/8/8/R3K3 b Qkq - 1 1"},
		{"capture on corner loses right", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "a1a8",
			"R3k2r/8/8/8/8/8/8/4K2R b Kk - 0 1"},
		{"promotion capture on corner loses right", "r3k2r/1P6/8/8/8/8/8/4K3 w kq - 0 1", "b7a8q",
			"Q3k2r/8/8/8/8/8/8/4K3 b k - 0 1"},
		{"promotion", "8/P1k5/K7/8/8/8/8/8 w - - 0 1", "a7a8n",
			"N7/2k5/K7/8/8/8/8/8 b - - 0 1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, err := ParseFEN(tt.fen)
			if err != nil {
				t.Fatal(err)
			}
			m, err := p.ParseMove(tt.move)
			if err != nil {
				t.Fatal(err)
			}
			before := p.FEN()
			q := p.Make(m)
			if got := q.FEN(); got != tt.want {
				t.Errorf("after %s: %s, want %s", tt.move, got, tt.want)
			}
			if p.FEN() != before {
				t.Error("Make modified its receiver")
			}
		})
	}
}

func TestCastlingRules(t *testing.T) {
	has := func(fen, move string) bool {
		p, err := ParseFEN(fen)
		if err != nil {
			t.Fatal(err)
		}
		_, err = p.ParseMove(move)
		return err == nil
	}
	tests := []struct {
		name, fen, move string
		want            bool
	}{
		{"allowed", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1c1", true},
		{"no right", "r3k2r/8/8/8/8/8/8/R3K2R w Kkq - 0 1", "e1c1", false},
		{"blocked on b1", "r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1", "e1c1", false},
		{"b1 may be attacked", "1r2k3/8/8/8/8/8/8/R3K3 w Q - 0 1", "e1c1", true},
		{"rook may be attacked", "r3k3/8/8/8/8/8/8/R3K3 b Qq - 0 1", "e8c8", true},
		{"rook h1 attacked", "k6r/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1", true},
		{"crossing attacked square", "k4r2/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1", false},
		{"landing attacked", "k5r1/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1", false},
		{"in check", "1k2r3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := has(tt.fen, tt.move); got != tt.want {
				t.Errorf("castling %s in %s: got %v, want %v", tt.move, tt.fen, got, tt.want)
			}
		})
	}
}

func TestInCheck(t *testing.T) {
	p, _ := ParseFEN("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")
	if !p.InCheck() {
		t.Error("expected check")
	}
	if StartPosition().InCheck() {
		t.Error("start position is not check")
	}
}
