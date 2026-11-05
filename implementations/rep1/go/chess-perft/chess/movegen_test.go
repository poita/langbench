package chess_test

import (
	"sort"
	"strings"
	"testing"

	"chessperft/chess"
)

func mustParse(t *testing.T, fen string) *chess.Position {
	t.Helper()
	p, err := chess.ParseFEN(fen)
	if err != nil {
		t.Fatalf("ParseFEN(%q): %v", fen, err)
	}
	return p
}

func moveStrings(p *chess.Position) []string {
	var out []string
	for _, m := range p.LegalMoves() {
		out = append(out, m.String())
	}
	sort.Strings(out)
	return out
}

func TestLegalMovesExact(t *testing.T) {
	cases := []struct {
		name, fen, want string
	}{
		{"promotion and king guard", "8/P1k5/K7/8/8/8/8/8 w - - 0 1",
			"a6a5 a6b5 a7a8b a7a8n a7a8q a7a8r"},
		{"stalemate", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", ""},
		{"checkmate", "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", ""},
		{"king x-ray behind itself", "4k3/8/8/8/8/8/8/r3K3 w - - 0 1", "e1d2 e1e2 e1f2"},
		{"double check king only", "4k3/8/8/8/1b6/5n2/8/R3K3 w - - 0 1", "e1d1 e1e2 e1f1 e1f2"},
		{"pinned rook slides on pin line", "4k3/4r3/8/8/8/8/4R3/4K3 w - - 0 1",
			"e2e3 e2e4 e2e5 e2e6 e2e7 e1d1 e1d2 e1f1 e1f2"},
		{"pinned knight never moves", "4k3/4r3/8/8/8/8/4N3/4K3 w - - 0 1", "e1d1 e1d2 e1f1 e1f2"},
		{"en passant", "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
			"e1d1 e1d2 e1e2 e1f1 e1f2 e5d6 e5e6"},
		{"ep target without capturing pawn", "4k3/8/8/3p4/8/8/4P3/4K3 w - d6 0 1",
			"e1d1 e1d2 e1f1 e1f2 e2e3 e2e4"},
		{"ep illegal: rank pin", "8/8/8/K2pP2r/8/8/8/4k3 w - d6 0 1",
			"a5a4 a5a6 a5b4 a5b5 a5b6 e5e6"},
		{"ep legal: captures the checking pawn", "8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1",
			"c5b4 c5b5 c5b6 c5c4 c5c6 c5d4 c5d5 c5d6 e4d3"},
		{"castling blocked and attacked", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
			"a1a2 a1a3 a1a4 a1a5 a1a6 a1a7 a1a8 a1b1 a1c1 a1d1 e1c1 e1d1 e1d2 e1e2 e1f1 e1f2 e1g1 h1f1 h1g1 h1h2 h1h3 h1h4 h1h5 h1h6 h1h7 h1h8"},
		{"no castling through attacked square", "4k3/8/8/8/8/8/5r2/R3K2R w KQ - 0 1",
			"a1a2 a1a3 a1a4 a1a5 a1a6 a1a7 a1a8 a1b1 a1c1 a1d1 e1c1 e1d1 e1f2 h1f1 h1g1 h1h2 h1h3 h1h4 h1h5 h1h6 h1h7 h1h8"},
		{"queenside castling with attacked b1", "1r2k3/8/8/8/8/8/8/R3K3 w Q - 0 1",
			"a1a2 a1a3 a1a4 a1a5 a1a6 a1a7 a1a8 a1b1 a1c1 a1d1 e1c1 e1d1 e1d2 e1e2 e1f1 e1f2"},
		{"no castling out of check", "4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1", "e1d1 e1e2 e1f1"},
	}
	for _, c := range cases {
		p := mustParse(t, c.fen)
		var want []string
		if c.want != "" {
			want = strings.Fields(c.want)
			sort.Strings(want)
		}
		got := moveStrings(p)
		if strings.Join(got, " ") != strings.Join(want, " ") {
			t.Errorf("%s:\n got  %v\n want %v", c.name, got, want)
		}
		if p.CountMoves() != len(want) {
			t.Errorf("%s: CountMoves = %d, want %d", c.name, p.CountMoves(), len(want))
		}
	}
}

func TestMoveAccessors(t *testing.T) {
	p := mustParse(t, "r3k2r/1P6/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1")
	seen := map[string]bool{}
	for _, m := range p.LegalMoves() {
		seen[m.String()] = true
		switch m.String() {
		case "b7a8q":
			if !m.IsPromotion() || m.Promotion() != chess.Queen {
				t.Error("b7a8q should promote to a queen")
			}
		case "e1g1", "e1c1":
			if !m.IsCastle() {
				t.Errorf("%v should be castling", m)
			}
		case "e5d6":
			if !m.IsEnPassant() {
				t.Error("e5d6 should be en passant")
			}
		}
	}
	for _, s := range []string{"b7a8q", "b7a8n", "b7b8r", "e1g1", "e1c1", "e5d6", "e5e6"} {
		if !seen[s] {
			t.Errorf("missing move %s", s)
		}
	}
	if _, err := p.ParseMove("e5d6"); err != nil {
		t.Error(err)
	}
	if _, err := p.ParseMove("e5e7"); err == nil {
		t.Error("e5e7 is not legal")
	}
}

func TestMakeUnmakeRestores(t *testing.T) {
	fens := []string{
		chess.StartFEN,
		"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
		"r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
		"r3k2r/1P6/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1",
	}
	for _, fen := range fens {
		p := mustParse(t, fen)
		before := p.FEN()
		for _, m := range p.LegalMoves() {
			u := p.Make(m)
			p.Unmake(m, u)
			if p.FEN() != before {
				t.Fatalf("%s: after %v make/unmake got %s", fen, m, p.FEN())
			}
		}
	}
}

func TestMakeEffects(t *testing.T) {
	p := mustParse(t, "r3k2r/1P6/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1")
	play := func(s string) {
		t.Helper()
		m, err := p.ParseMove(s)
		if err != nil {
			t.Fatal(err)
		}
		p.Make(m)
	}
	play("e1g1") // castling moves the rook, drops white's rights
	if p.FEN() != "r3k2r/1P6/8/3pP3/8/8/8/R4RK1 b kq - 0 1" {
		t.Errorf("after e1g1: %s", p.FEN())
	}
	play("a8a1") // captures the rook on a1 (rights already gone for white)
	play("g1g2")
	if p.Castling() != chess.CastleBlackKing {
		t.Errorf("rights = %b, want only black kingside", p.Castling())
	}

	p = mustParse(t, "r3k2r/1P6/8/8/8/8/8/R3K2R w KQkq - 0 1")
	play("b7a8q") // promotion capture on a corner removes black's queenside right
	if p.Castling()&chess.CastleBlackQueen != 0 {
		t.Error("capturing the a8 rook must remove the queenside right")
	}

	p = mustParse(t, "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
	play("e2e4")
	if p.EnPassant().String() != "e3" {
		t.Errorf("ep after double push = %v, want e3", p.EnPassant())
	}
	play("e8e7")
	if p.EnPassant() != chess.NoSquare {
		t.Error("ep must clear after any other move")
	}

	p = mustParse(t, "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
	play("e5d6")
	if got := p.FEN(); got != "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1" {
		t.Errorf("after en passant: %s", got)
	}
}

func TestRookRecaptureDoesNotRestoreRights(t *testing.T) {
	p := mustParse(t, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	for _, s := range []string{"a1a8", "e8d7", "a8a1"} {
		m, err := p.ParseMove(s)
		if err != nil {
			t.Fatal(err)
		}
		p.Make(m)
	}
	if p.Castling() != chess.CastleWhiteKing { // black king moved, white lost queenside twice
		t.Errorf("rights = %b", p.Castling())
	}
}
