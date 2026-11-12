package chess

// Color is the side to move or the owner of a piece.
type Color uint8

// The two colors.
const (
	White Color = iota
	Black
)

// Opposite returns the other color.
func (c Color) Opposite() Color { return c ^ 1 }

// String returns "w" or "b", as used in FEN.
func (c Color) String() string {
	if c == White {
		return "w"
	}
	return "b"
}

// PieceType is a kind of chessman without a color.
type PieceType uint8

// The six piece types.
const (
	Pawn PieceType = iota
	Knight
	Bishop
	Rook
	Queen
	King
)

// Piece is a colored chessman. The zero value, [NoPiece], is an empty square.
type Piece uint8

// NoPiece is the content of an empty square.
const NoPiece Piece = 0

// NewPiece returns the piece of color c and type t.
func NewPiece(c Color, t PieceType) Piece { return Piece(1+uint8(t)) | Piece(c)<<3 }

// Type returns the type of p. It is meaningless for [NoPiece].
func (p Piece) Type() PieceType { return PieceType(p&7) - 1 }

// Color returns the color of p. It is meaningless for [NoPiece].
func (p Piece) Color() Color { return Color(p >> 3) }

const pieceChars = "PNBRQK"

// String returns the FEN letter of p (upper case for white), or "" for
// [NoPiece].
func (p Piece) String() string {
	if p == NoPiece {
		return ""
	}
	ch := pieceChars[p.Type()]
	if p.Color() == Black {
		ch += 'a' - 'A'
	}
	return string(ch)
}

// pieceFromChar converts a FEN letter to a Piece.
func pieceFromChar(ch byte) (Piece, bool) {
	c := White
	if ch >= 'a' && ch <= 'z' {
		c = Black
		ch -= 'a' - 'A'
	}
	for i := 0; i < len(pieceChars); i++ {
		if pieceChars[i] == ch {
			return NewPiece(c, PieceType(i)), true
		}
	}
	return NoPiece, false
}
