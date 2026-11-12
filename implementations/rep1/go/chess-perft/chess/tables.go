package chess

// Precomputed attack data. Everything here is filled in once by init and is
// read-only afterwards, so it is safe for concurrent use.

// Ray directions. Indices 0-3 move towards higher square numbers and 4-7
// towards lower ones; direction d and (d+4)%8 are opposites.
const (
	dirN = iota
	dirE
	dirNE
	dirNW
	dirS
	dirW
	dirSW
	dirSE
)

var dirDelta = [8][2]int{ // {file, rank}
	dirN: {0, 1}, dirE: {1, 0}, dirNE: {1, 1}, dirNW: {-1, 1},
	dirS: {0, -1}, dirW: {-1, 0}, dirSW: {-1, -1}, dirSE: {1, -1},
}

var (
	knightAtt  [64]Bitboard
	kingAtt    [64]Bitboard
	pawnAtt    [2][64]Bitboard // pawnAtt[c][s]: squares attacked by a pawn of color c on s
	rays       [8][64]Bitboard // squares strictly beyond s in a direction, to the board edge
	between    [64][64]Bitboard
	line       [64][64]Bitboard // the full line through two aligned squares, else 0
	rookRays   [64]Bitboard     // rook attacks on an empty board
	bishopRays [64]Bitboard     // bishop attacks on an empty board
)

func onBoard(f, r int) bool { return f >= 0 && f < 8 && r >= 0 && r < 8 }

func init() {
	for s := Square(0); s < 64; s++ {
		f, r := s.File(), s.Rank()
		for _, d := range [][2]int{{1, 2}, {2, 1}, {-1, 2}, {-2, 1}, {1, -2}, {2, -1}, {-1, -2}, {-2, -1}} {
			if onBoard(f+d[0], r+d[1]) {
				knightAtt[s] |= NewSquare(f+d[0], r+d[1]).Bit()
			}
		}
		for d := 0; d < 8; d++ {
			if onBoard(f+dirDelta[d][0], r+dirDelta[d][1]) {
				kingAtt[s] |= NewSquare(f+dirDelta[d][0], r+dirDelta[d][1]).Bit()
			}
			for ff, rr := f+dirDelta[d][0], r+dirDelta[d][1]; onBoard(ff, rr); ff, rr = ff+dirDelta[d][0], rr+dirDelta[d][1] {
				rays[d][s] |= NewSquare(ff, rr).Bit()
			}
		}
		for _, df := range []int{-1, 1} {
			if onBoard(f+df, r+1) {
				pawnAtt[White][s] |= NewSquare(f+df, r+1).Bit()
			}
			if onBoard(f+df, r-1) {
				pawnAtt[Black][s] |= NewSquare(f+df, r-1).Bit()
			}
		}
		rookRays[s] = rays[dirN][s] | rays[dirE][s] | rays[dirS][s] | rays[dirW][s]
		bishopRays[s] = rays[dirNE][s] | rays[dirNW][s] | rays[dirSE][s] | rays[dirSW][s]
	}
	for a := Square(0); a < 64; a++ {
		for d := 0; d < 8; d++ {
			full := rays[d][a] | rays[(d+4)%8][a] | a.Bit()
			for rest := rays[d][a]; rest != 0; {
				b := rest.Pop()
				between[a][b] = rays[d][a] &^ rays[d][b] &^ b.Bit()
				line[a][b] = full
			}
		}
	}
}

// slide returns the squares a slider on s attacks in direction d, given the
// occupancy occ. The first blocker is included.
func slide(d int, s Square, occ Bitboard) Bitboard {
	a := rays[d][s]
	if blockers := a & occ; blockers != 0 {
		if d < 4 {
			a &^= rays[d][blockers.Lsb()]
		} else {
			a &^= rays[d][blockers.Msb()]
		}
	}
	return a
}

// RookAttacks returns the squares attacked by a rook on s with the given
// board occupancy.
func RookAttacks(s Square, occ Bitboard) Bitboard {
	return slide(dirN, s, occ) | slide(dirE, s, occ) | slide(dirS, s, occ) | slide(dirW, s, occ)
}

// BishopAttacks returns the squares attacked by a bishop on s with the given
// board occupancy.
func BishopAttacks(s Square, occ Bitboard) Bitboard {
	return slide(dirNE, s, occ) | slide(dirNW, s, occ) | slide(dirSE, s, occ) | slide(dirSW, s, occ)
}

// QueenAttacks returns the squares attacked by a queen on s with the given
// board occupancy.
func QueenAttacks(s Square, occ Bitboard) Bitboard {
	return RookAttacks(s, occ) | BishopAttacks(s, occ)
}

// KnightAttacks returns the squares attacked by a knight on s.
func KnightAttacks(s Square) Bitboard { return knightAtt[s] }

// KingAttacks returns the squares attacked by a king on s.
func KingAttacks(s Square) Bitboard { return kingAtt[s] }

// PawnAttacks returns the squares attacked by a pawn of color c on s.
func PawnAttacks(c Color, s Square) Bitboard { return pawnAtt[c][s] }
