package chess

import (
	"fmt"
	"math/bits"
	"strings"
)

// Bitboard is a set of squares; bit i is set when square i is a member.
type Bitboard uint64

// Square is a board square, numbered rank*8+file with a1 = 0 and h8 = 63.
type Square uint8

// NoSquare is the sentinel for "no square" (for example, no en passant target).
const NoSquare Square = 64

// Useful squares.
const (
	A1 Square = 0
	C1 Square = 2
	E1 Square = 4
	G1 Square = 6
	H1 Square = 7
	A8 Square = 56
	E8 Square = 60
	H8 Square = 63
)

// Color is a side: White or Black.
type Color uint8

// The two sides.
const (
	White Color = iota
	Black
)

// Opponent returns the other side.
func (c Color) Opponent() Color { return c ^ 1 }

// PieceType is a kind of piece regardless of colour.
type PieceType uint8

// The piece types, in the order used for indexing.
const (
	Pawn PieceType = iota
	Knight
	Bishop
	Rook
	Queen
	King
)

// Piece is a coloured piece, or NoPiece for an empty square.
type Piece uint8

// NoPiece marks an empty square in the mailbox.
const NoPiece Piece = 12

// Pieces that are referred to by name in the package.
const (
	WhitePawn Piece = Piece(Pawn)
	BlackPawn Piece = 6 + Piece(Pawn)
)

// MakePiece builds a Piece from a colour and a type.
func MakePiece(c Color, t PieceType) Piece { return Piece(c)*6 + Piece(t) }

// Type returns the piece type. It must not be called on NoPiece.
func (p Piece) Type() PieceType { return PieceType(p % 6) }

// Color returns the piece colour. It must not be called on NoPiece.
func (p Piece) Color() Color { return Color(p / 6) }

const pieceChars = "PNBRQKpnbrqk"

// String returns the FEN letter of the piece, or "." for NoPiece.
func (p Piece) String() string {
	if p >= NoPiece {
		return "."
	}
	return pieceChars[p : p+1]
}

// Rank and file masks.
const (
	FileA Bitboard = 0x0101010101010101
	FileH Bitboard = FileA << 7
	Rank1 Bitboard = 0xFF
	Rank3 Bitboard = Rank1 << 16
	Rank6 Bitboard = Rank1 << 40
	Rank8 Bitboard = Rank1 << 56
)

// MakeSquare returns the square for a zero-based file (0 = a) and rank (0 = 1).
func MakeSquare(file, rank int) Square { return Square(rank*8 + file) }

// File returns the zero-based file of the square (0 = a).
func (s Square) File() int { return int(s & 7) }

// Rank returns the zero-based rank of the square (0 = rank 1).
func (s Square) Rank() int { return int(s >> 3) }

// Bitboard returns the single-square set containing s.
func (s Square) Bitboard() Bitboard { return 1 << s }

// String returns the algebraic name such as "e4", or "-" for NoSquare.
func (s Square) String() string {
	if s >= NoSquare {
		return "-"
	}
	return string([]byte{byte('a' + s.File()), byte('1' + s.Rank())})
}

// ParseSquare parses an algebraic square name such as "e4".
func ParseSquare(s string) (Square, error) {
	if len(s) != 2 || s[0] < 'a' || s[0] > 'h' || s[1] < '1' || s[1] > '8' {
		return NoSquare, fmt.Errorf("chess: invalid square %q", s)
	}
	return MakeSquare(int(s[0]-'a'), int(s[1]-'1')), nil
}

// Count returns the number of squares in the set.
func (b Bitboard) Count() int { return bits.OnesCount64(uint64(b)) }

// Lsb returns the lowest-numbered square in a non-empty set.
func (b Bitboard) Lsb() Square { return Square(bits.TrailingZeros64(uint64(b))) }

// Msb returns the highest-numbered square in a non-empty set.
func (b Bitboard) Msb() Square { return Square(63 - bits.LeadingZeros64(uint64(b))) }

// PopLsb removes and returns the lowest-numbered square of a non-empty set.
func (b *Bitboard) PopLsb() Square {
	s := Square(bits.TrailingZeros64(uint64(*b)))
	*b &= *b - 1
	return s
}

// Has reports whether the set contains s.
func (b Bitboard) Has(s Square) bool { return b>>s&1 != 0 }

// MoreThanOne reports whether the set has two or more members.
func (b Bitboard) MoreThanOne() bool { return b&(b-1) != 0 }

// String renders the set as an 8x8 diagram, rank 8 at the top.
func (b Bitboard) String() string {
	var sb strings.Builder
	for r := 7; r >= 0; r-- {
		for f := 0; f < 8; f++ {
			if b.Has(MakeSquare(f, r)) {
				sb.WriteByte('X')
			} else {
				sb.WriteByte('.')
			}
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}
