package chess

import "fmt"

// Move is a compact 16-bit move: bits 0-5 origin, bits 6-11 destination and
// bits 12-15 a flag. A move does not record what it captures; Make reads that
// from the board.
type Move uint16

// Move flags (bits 12-15).
const (
	flagQuiet  = 0
	flagDouble = 1 // pawn two-square advance
	flagEP     = 2 // en passant capture
	flagCastle = 3 // king move of a castling
	flagPromoN = 4 // promotions: flagPromoN + (type - Knight)
	flagPromoB = 5
	flagPromoR = 6
	flagPromoQ = 7
)

// NoMove is the zero Move (a1a1), never produced by the generator.
const NoMove Move = 0

func newMove(from, to Square, flag int) Move {
	return Move(from) | Move(to)<<6 | Move(flag)<<12
}

// From returns the origin square.
func (m Move) From() Square { return Square(m & 63) }

// To returns the destination square. Castling is the king's destination.
func (m Move) To() Square { return Square(m >> 6 & 63) }

func (m Move) flag() int { return int(m >> 12) }

// IsPromotion reports whether the move promotes a pawn.
func (m Move) IsPromotion() bool { return m.flag() >= flagPromoN }

// Promotion returns the piece type a pawn promotes to (Knight, Bishop, Rook or
// Queen); it is only meaningful when IsPromotion is true.
func (m Move) Promotion() PieceType { return PieceType(m.flag()-flagPromoN) + Knight }

// IsEnPassant reports whether the move is an en passant capture.
func (m Move) IsEnPassant() bool { return m.flag() == flagEP }

// IsCastle reports whether the move is a castling move.
func (m Move) IsCastle() bool { return m.flag() == flagCastle }

// IsDoublePush reports whether the move is a two-square pawn advance.
func (m Move) IsDoublePush() bool { return m.flag() == flagDouble }

// String returns the move in UCI long algebraic notation, e.g. "e2e4",
// "e1g1" or "a7a8q".
func (m Move) String() string {
	b := [5]byte{}
	f, t := m.From(), m.To()
	b[0], b[1] = byte('a'+f.File()), byte('1'+f.Rank())
	b[2], b[3] = byte('a'+t.File()), byte('1'+t.Rank())
	if m.IsPromotion() {
		b[4] = "nbrq"[m.Promotion()-Knight]
		return string(b[:5])
	}
	return string(b[:4])
}

// ParseMove finds the legal move of the position whose UCI string is s.
func (p *Position) ParseMove(s string) (Move, error) {
	for _, m := range p.LegalMoves() {
		if m.String() == s {
			return m, nil
		}
	}
	return NoMove, fmt.Errorf("chess: %q is not a legal move in %s", s, p.FEN())
}
