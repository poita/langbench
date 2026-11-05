package chess

import "math/bits"

// Ray directions. The order is chosen so that the opposite of d is (d+4)%8.
const (
	dirN = iota
	dirNE
	dirE
	dirSE
	dirS
	dirSW
	dirW
	dirNW
)

var (
	dirDFile = [8]int{0, 1, 1, 1, 0, -1, -1, -1}
	dirDRank = [8]int{1, 1, 0, -1, -1, -1, 0, 1}
)

// Precomputed tables, built once in init and read-only afterwards.
var (
	knightAttacks [64]Bitboard
	kingAttacks   [64]Bitboard
	pawnAttacks   [2][64]Bitboard // pawnAttacks[c][s]: squares attacked by a pawn of colour c on s

	rays       [8][64]Bitboard // squares from s outward in one direction, excluding s
	rookRays   [64]Bitboard    // empty-board rook attacks
	bishopRays [64]Bitboard    // empty-board bishop attacks
	betweenBB  [64][64]Bitboard
	lineBB     [64][64]Bitboard
	castleMask [64]uint8 // castling rights that survive a move touching the square
)

// Castling right bits.
const (
	CastleWhiteKing  uint8 = 1
	CastleWhiteQueen uint8 = 2
	CastleBlackKing  uint8 = 4
	CastleBlackQueen uint8 = 8
	castleAll        uint8 = 15
)

func init() {
	for s := Square(0); s < 64; s++ {
		f, r := s.File(), s.Rank()
		for d := 0; d < 8; d++ {
			for nf, nr := f+dirDFile[d], r+dirDRank[d]; onBoard(nf, nr); nf, nr = nf+dirDFile[d], nr+dirDRank[d] {
				rays[d][s] |= MakeSquare(nf, nr).Bitboard()
			}
		}
		rookRays[s] = rays[dirN][s] | rays[dirE][s] | rays[dirS][s] | rays[dirW][s]
		bishopRays[s] = rays[dirNE][s] | rays[dirSE][s] | rays[dirSW][s] | rays[dirNW][s]

		for _, d := range [][2]int{{1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2}} {
			if onBoard(f+d[0], r+d[1]) {
				knightAttacks[s] |= MakeSquare(f+d[0], r+d[1]).Bitboard()
			}
		}
		for d := 0; d < 8; d++ {
			if onBoard(f+dirDFile[d], r+dirDRank[d]) {
				kingAttacks[s] |= MakeSquare(f+dirDFile[d], r+dirDRank[d]).Bitboard()
			}
		}
		for _, df := range []int{-1, 1} {
			if onBoard(f+df, r+1) {
				pawnAttacks[White][s] |= MakeSquare(f+df, r+1).Bitboard()
			}
			if onBoard(f+df, r-1) {
				pawnAttacks[Black][s] |= MakeSquare(f+df, r-1).Bitboard()
			}
		}
	}

	// Between and line sets, derived from the rays.
	for a := Square(0); a < 64; a++ {
		for d := 0; d < 8; d++ {
			opp := (d + 4) % 8
			full := rays[d][a] | rays[opp][a] | a.Bitboard()
			for t := rays[d][a]; t != 0; {
				b := t.PopLsb()
				betweenBB[a][b] = rays[d][a] &^ (rays[d][b] | b.Bitboard())
				lineBB[a][b] = full
			}
		}
	}

	// Castling rights lost when a move touches a square.
	for i := range castleMask {
		castleMask[i] = castleAll
	}
	castleMask[A1] &^= CastleWhiteQueen
	castleMask[H1] &^= CastleWhiteKing
	castleMask[E1] &^= CastleWhiteKing | CastleWhiteQueen
	castleMask[A8] &^= CastleBlackQueen
	castleMask[H8] &^= CastleBlackKing
	castleMask[E8] &^= CastleBlackKing | CastleBlackQueen
}

func onBoard(f, r int) bool { return f >= 0 && f < 8 && r >= 0 && r < 8 }

// Between returns the squares strictly between a and b when they share a rank,
// file or diagonal, and the empty set otherwise.
func Between(a, b Square) Bitboard { return betweenBB[a][b] }

// Line returns the whole rank, file or diagonal through a and b (including both)
// when they are aligned, and the empty set otherwise.
func Line(a, b Square) Bitboard { return lineBB[a][b] }

// KnightAttacks returns the squares a knight on s attacks.
func KnightAttacks(s Square) Bitboard { return knightAttacks[s] }

// KingAttacks returns the squares a king on s attacks.
func KingAttacks(s Square) Bitboard { return kingAttacks[s] }

// PawnAttacks returns the squares a pawn of colour c on s attacks.
func PawnAttacks(c Color, s Square) Bitboard { return pawnAttacks[c][s] }

// posRay returns the attacks along a ray whose squares increase in index
// (the nearest blocker is the lowest set bit).
func posRay(d int, s Square, occ Bitboard) Bitboard {
	r := rays[d][s]
	if b := r & occ; b != 0 {
		r ^= rays[d][bits.TrailingZeros64(uint64(b))]
	}
	return r
}

// negRay is posRay for rays whose squares decrease in index (the nearest
// blocker is the highest set bit).
func negRay(d int, s Square, occ Bitboard) Bitboard {
	r := rays[d][s]
	if b := r & occ; b != 0 {
		r ^= rays[d][63-bits.LeadingZeros64(uint64(b))]
	}
	return r
}

// BishopAttacks returns the squares a bishop on s attacks given occupancy occ.
// Blocking squares are included in the result.
func BishopAttacks(s Square, occ Bitboard) Bitboard {
	return posRay(dirNE, s, occ) | posRay(dirNW, s, occ) |
		negRay(dirSE, s, occ) | negRay(dirSW, s, occ)
}

// RookAttacks returns the squares a rook on s attacks given occupancy occ.
// Blocking squares are included in the result.
func RookAttacks(s Square, occ Bitboard) Bitboard {
	return posRay(dirN, s, occ) | posRay(dirE, s, occ) |
		negRay(dirS, s, occ) | negRay(dirW, s, occ)
}

// QueenAttacks returns the squares a queen on s attacks given occupancy occ.
func QueenAttacks(s Square, occ Bitboard) Bitboard {
	return BishopAttacks(s, occ) | RookAttacks(s, occ)
}
