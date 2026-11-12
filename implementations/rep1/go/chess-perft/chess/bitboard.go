package chess

import (
	"fmt"
	"math/bits"
)

// Bitboard is a set of squares, one bit per square. Bit i is set when square i
// (see [Square]) is in the set.
type Bitboard uint64

// Square identifies a board square: a1 = 0, b1 = 1, ..., h1 = 7, a2 = 8, ...,
// h8 = 63. The value [NoSquare] means "no square".
type Square uint8

// NoSquare is the sentinel for the absence of a square (for example, no en
// passant target).
const NoSquare Square = 64

// Square constants for the squares the move generator refers to by name.
const (
	A1 Square = 0
	E1 Square = 4
	H1 Square = 7
	A8 Square = 56
	E8 Square = 60
	H8 Square = 63
)

// NewSquare returns the square on the given file and rank, both in 0..7
// (file 0 is the a-file, rank 0 is rank 1).
func NewSquare(file, rank int) Square { return Square(rank*8 + file) }

// File returns the file of s in 0..7 (0 is the a-file).
func (s Square) File() int { return int(s) & 7 }

// Rank returns the rank of s in 0..7 (0 is rank 1).
func (s Square) Rank() int { return int(s) >> 3 }

// String returns the algebraic name of s such as "e4", or "-" for [NoSquare].
func (s Square) String() string {
	if s >= NoSquare {
		return "-"
	}
	return string([]byte{byte('a' + s.File()), byte('1' + s.Rank())})
}

// ParseSquare parses an algebraic square name such as "e4".
func ParseSquare(str string) (Square, error) {
	if len(str) != 2 || str[0] < 'a' || str[0] > 'h' || str[1] < '1' || str[1] > '8' {
		return NoSquare, fmt.Errorf("chess: invalid square %q", str)
	}
	return NewSquare(int(str[0]-'a'), int(str[1]-'1')), nil
}

// Bit returns the bitboard containing only s.
func (s Square) Bit() Bitboard { return Bitboard(1) << s }

// Count returns the number of squares in b.
func (b Bitboard) Count() int { return bits.OnesCount64(uint64(b)) }

// Has reports whether s is in b.
func (b Bitboard) Has(s Square) bool { return b&s.Bit() != 0 }

// Lsb returns the lowest-numbered square in b. b must not be empty.
func (b Bitboard) Lsb() Square { return Square(bits.TrailingZeros64(uint64(b))) }

// Msb returns the highest-numbered square in b. b must not be empty.
func (b Bitboard) Msb() Square { return Square(63 - bits.LeadingZeros64(uint64(b))) }

// Pop removes and returns the lowest-numbered square of b. b must not be empty.
func (b *Bitboard) Pop() Square {
	s := b.Lsb()
	*b &= *b - 1
	return s
}

// String renders b as an 8x8 grid, rank 8 first, for debugging.
func (b Bitboard) String() string {
	out := make([]byte, 0, 80)
	for r := 7; r >= 0; r-- {
		for f := 0; f < 8; f++ {
			if b.Has(NewSquare(f, r)) {
				out = append(out, 'X')
			} else {
				out = append(out, '.')
			}
		}
		out = append(out, '\n')
	}
	return string(out)
}
