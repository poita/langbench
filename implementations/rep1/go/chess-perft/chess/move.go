package chess

import "fmt"

// Move is a chess move packed into 16 bits: origin square (6 bits),
// destination square (6 bits) and promotion piece type (4 bits).
//
// Castling is represented as the king's two-square move, and an en passant
// capture as the capturing pawn's diagonal move to the en passant square, as in
// UCI; [Position.Make] recognises both from the position.
type Move uint16

// noPromo is stored in the promotion field of a non-promoting move.
const noPromo = 0

// NewMove builds a move. promo is the piece type promoted to, and is ignored
// unless promoting is true.
func NewMove(from, to Square, promo PieceType, promoting bool) Move {
	m := Move(from) | Move(to)<<6
	if promoting {
		m |= Move(promo+1) << 12
	}
	return m
}

// From returns the origin square.
func (m Move) From() Square { return Square(m & 63) }

// To returns the destination square.
func (m Move) To() Square { return Square(m >> 6 & 63) }

// Promotion returns the piece type a pawn promotes to and true, or false if m
// is not a promotion.
func (m Move) Promotion() (PieceType, bool) {
	p := m >> 12
	if p == noPromo {
		return 0, false
	}
	return PieceType(p - 1), true
}

// String returns m in UCI long algebraic notation, such as "e2e4", "e1g1" or
// "a7a8q".
func (m Move) String() string {
	s := m.From().String() + m.To().String()
	if p, ok := m.Promotion(); ok {
		s += string(pieceChars[p] + 'a' - 'A')
	}
	return s
}

// ParseMove parses a UCI move string and returns the matching legal move of p.
func (p *Position) ParseMove(s string) (Move, error) {
	for _, m := range p.LegalMoves() {
		if m.String() == s {
			return m, nil
		}
	}
	return 0, fmt.Errorf("chess: %q is not a legal move in %s", s, p.FEN())
}
