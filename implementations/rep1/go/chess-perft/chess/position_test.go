package chess_test

import (
	"testing"

	"chessperft/chess"
)

func TestParseFENRoundTrip(t *testing.T) {
	for _, fen := range []string{
		chess.StartFEN,
		"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
		"rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
		"rnbqkbnr/pppp1ppp/8/8/3Pp3/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 3",
		"8/8/8/8/8/8/8/K6k w - - 12 40",
	} {
		p, err := chess.ParseFEN(fen)
		if err != nil {
			t.Errorf("ParseFEN(%q): %v", fen, err)
			continue
		}
		if got := p.FEN(); got != fen {
			t.Errorf("FEN round trip: got %q want %q", got, fen)
		}
	}
}

func TestParseFENAccessors(t *testing.T) {
	p := chess.NewPosition()
	if p.SideToMove() != chess.White || p.Castling() != 15 || p.EnPassant() != chess.NoSquare {
		t.Error("start position state wrong")
	}
	e1, _ := chess.ParseSquare("e1")
	if pc := p.PieceAt(e1); pc != chess.MakePiece(chess.White, chess.King) {
		t.Errorf("e1 holds %v", pc)
	}
	if p.Occupied().Count() != 32 {
		t.Error("start position should have 32 pieces")
	}
	if p.Pieces(chess.Black, chess.Pawn).Count() != 8 {
		t.Error("expected 8 black pawns")
	}
	if p.InCheck() {
		t.Error("start position is not check")
	}
	q, _ := chess.ParseFEN("rnbqkbnr/pppp1ppp/8/8/3Pp3/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 3")
	if q.EnPassant().String() != "d3" || q.SideToMove() != chess.Black {
		t.Error("ep/side parse wrong")
	}
}

func TestParseFENErrors(t *testing.T) {
	bad := map[string]string{
		"too few fields":      "8/8/8/8/8/8/8/K6k w - -",
		"seven ranks":         "8/8/8/8/8/8/K6k w - - 0 1",
		"short rank":          "8/8/8/8/8/8/8/K5k w - - 0 1",
		"long rank":           "8/8/8/8/8/8/8/K6kk w - - 0 1",
		"unknown piece":       "8/8/8/8/8/8/8/K6x w - - 0 1",
		"bad side":            "8/8/8/8/8/8/8/K6k x - - 0 1",
		"bad castling":        "8/8/8/8/8/8/8/K6k w X - 0 1",
		"bad ep":              "8/8/8/8/8/8/8/K6k w - e9 0 1",
		"bad clock":           "8/8/8/8/8/8/8/K6k w - - x 1",
		"no black king":       "8/8/8/8/8/8/8/K7 w - - 0 1",
		"two white kings":     "8/8/8/8/8/8/8/KK5k w - - 0 1",
		"pawn on first rank":  "8/8/8/8/8/8/8/K5Pk w - - 0 1",
		"pawn on last rank":   "p7/8/8/8/8/8/8/K6k w - - 0 1",
		"castling no rook":    "4k3/8/8/8/8/8/8/4K3 w K - 0 1",
		"opponent in check":   "R3k3/8/8/8/8/8/8/4K3 w - - 0 1",
		"empty":               "",
		"extra field":         "8/8/8/8/8/8/8/K6k w - - 0 1 7",
		"castling mixed case": "r3k2r/8/8/8/8/8/8/R3K2R w Kx - 0 1",
	}
	for name, fen := range bad {
		if _, err := chess.ParseFEN(fen); err == nil {
			t.Errorf("%s: ParseFEN(%q) succeeded, want error", name, fen)
		}
	}
}

func TestSquareHelpers(t *testing.T) {
	for _, s := range []string{"a1", "h8", "e4", "c7"} {
		v, err := chess.ParseSquare(s)
		if err != nil || v.String() != s {
			t.Errorf("ParseSquare(%q) = %v, %v", s, v, err)
		}
	}
	for _, s := range []string{"", "a", "i1", "a0", "a9", "A1", "e44"} {
		if _, err := chess.ParseSquare(s); err == nil {
			t.Errorf("ParseSquare(%q) should fail", s)
		}
	}
	if chess.MakeSquare(4, 3).String() != "e4" {
		t.Error("MakeSquare(4,3) should be e4")
	}
	if chess.NoSquare.String() != "-" {
		t.Error("NoSquare should print as -")
	}
}

func TestIsAttacked(t *testing.T) {
	p, _ := chess.ParseFEN("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")
	e1, _ := chess.ParseSquare("e1")
	if !p.InCheck() || !p.IsAttacked(e1, chess.Black) {
		t.Error("king on e1 should be in check from e2")
	}
	d1, _ := chess.ParseSquare("d1")
	d2, _ := chess.ParseSquare("d2")
	if p.IsAttacked(d1, chess.Black) || !p.IsAttacked(d2, chess.Black) {
		t.Error("the rook on e2 attacks d2 but not d1")
	}
	if p.IsAttacked(d1, chess.White) != true {
		t.Error("the white king attacks d1")
	}
}
