// Package cube models a 3x3x3 Rubik's cube.
//
// A [Cube] is stored at the cubie level: which corner or edge piece sits in
// each slot and how it is twisted or flipped. The package also converts from
// and to the 54-sticker facelet view, and defines the eighteen face turns
// (U D L R F B, each as a quarter turn, its inverse and a half turn) as the
// type [Move].
//
// # Conventions
//
// Faces are ordered U, R, F, D, L, B. Corner slots are numbered
// URF, UFL, ULB, UBR, DFR, DLF, DBL, DRB and edge slots
// UR, UF, UL, UB, DR, DF, DL, DB, FR, FL, BL, BR. Facelets are numbered
// face*9 + (n-1) where n is the 1-9 sticker number in reading order on that
// face, exactly as in the unfolded net below:
//
//	           +----------+
//	           | U1 U2 U3 |
//	           | U4 U5 U6 |
//	           | U7 U8 U9 |
//	+----------+----------+----------+----------+
//	| L1 L2 L3 | F1 F2 F3 | R1 R2 R3 | B1 B2 B3 |
//	| L4 L5 L6 | F4 F5 F6 | R4 R5 R6 | B4 B5 B6 |
//	| L7 L8 L9 | F7 F8 F9 | R7 R8 R9 | B7 B8 B9 |
//	+----------+----------+----------+----------+
//	           | D1 D2 D3 |
//	           | D4 D5 D6 |
//	           | D7 D8 D9 |
//	           +----------+
//
// A corner's orientation is the position (0, 1 or 2) within its slot's
// facelet triple of the piece's U or D sticker. An edge's orientation is 0
// when the piece's first colour lies on the slot's first facelet, else 1.
// With these conventions F and B quarter turns are the only moves that flip
// edges, and L and R quarter turns (besides F and B) twist corners.
package cube
