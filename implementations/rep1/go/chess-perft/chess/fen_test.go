package chess

import (
	"strings"
	"testing"
)

func TestFENRoundTrip(t *testing.T) {
	for _, tc := range perftCases {
		p, err := ParseFEN(tc.fen)
		if err != nil {
			t.Fatal(err)
		}
		if got := p.FEN(); got != tc.fen {
			t.Errorf("FEN() = %q, want %q", got, tc.fen)
		}
	}
}

func TestParseFENFields(t *testing.T) {
	p, err := ParseFEN("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b Kq e3 7 12")
	if err != nil {
		t.Fatal(err)
	}
	if p.SideToMove() != Black || p.EnPassant() != 20 || p.HalfmoveClock() != 7 || p.FullmoveNumber() != 12 {
		t.Errorf("unexpected fields in %s", p.FEN())
	}
	if p.Castling() != CastleWhiteKing|CastleBlackQueen {
		t.Errorf("castling = %b", p.Castling())
	}
	if p.PieceAt(4) != NewPiece(White, King) || p.KingSquare(Black) != E8 {
		t.Error("wrong pieces")
	}
	if q, err := ParseFEN("4k3/8/8/8/8/8/8/4K3 w - -"); err != nil || q.FullmoveNumber() != 1 {
		t.Errorf("four-field FEN: %v", err)
	}
}

func TestParseFENErrors(t *testing.T) {
	bad := map[string]string{
		"too few fields":       "8/8/8/8/8/8/8/8 w",
		"seven ranks":          "4k3/8/8/8/8/8/4K3 w - - 0 1",
		"short rank":           "4k3/8/8/8/8/8/8/3K3 w - - 0 1",
		"long rank":            "4k3/8/8/8/8/8/8/4K4 w - - 0 1",
		"bad piece":            "4k3/8/8/8/8/8/8/4X3 w - - 0 1",
		"no white king":        "4k3/8/8/8/8/8/8/8 w - - 0 1",
		"two black kings":      "4k3/8/8/8/8/8/8/k3K3 w - - 0 1",
		"bad side":             "4k3/8/8/8/8/8/8/4K3 x - - 0 1",
		"pawn on back rank":    "4k2P/8/8/8/8/8/8/4K3 w - - 0 1",
		"castling order":       "r3k2r/8/8/8/8/8/8/R3K2R w qK - 0 1",
		"castling w/o rook":    "4k3/8/8/8/8/8/8/4K3 w K - 0 1",
		"bad ep rank":          "4k3/8/8/8/4P3/8/8/4K3 b - e4 0 1",
		"ep without pawn":      "4k3/8/8/8/8/8/8/4K3 b - e3 0 1",
		"side not to move att": "4k3/8/8/8/8/8/4R3/4K3 w - - 0 1",
		"bad halfmove":         "4k3/8/8/8/8/8/8/4K3 w - - x 1",
	}
	for name, fen := range bad {
		if _, err := ParseFEN(fen); err == nil {
			t.Errorf("%s: ParseFEN(%q) succeeded, want error", name, fen)
		} else if !strings.HasPrefix(err.Error(), "chess:") {
			t.Errorf("%s: error %q lacks package prefix", name, err)
		}
	}
}

func TestSquareAndMoveText(t *testing.T) {
	for _, s := range []string{"a1", "h1", "e4", "h8"} {
		sq, err := ParseSquare(s)
		if err != nil || sq.String() != s {
			t.Errorf("ParseSquare(%q) = %v, %v", s, sq, err)
		}
	}
	for _, s := range []string{"", "a", "i1", "a9", "e44"} {
		if _, err := ParseSquare(s); err == nil {
			t.Errorf("ParseSquare(%q) should fail", s)
		}
	}
	m := NewMove(48, 56, Knight, true)
	if m.String() != "a7a8n" {
		t.Errorf("got %s", m)
	}
	if pt, ok := m.Promotion(); !ok || pt != Knight {
		t.Error("promotion not recovered")
	}
	if _, ok := NewMove(12, 28, 0, false).Promotion(); ok {
		t.Error("unexpected promotion")
	}
	if _, err := StartPosition().ParseMove("e2e5"); err == nil {
		t.Error("illegal move accepted")
	}
}
