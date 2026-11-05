// Package cube models a 3x3x3 Rubik's cube.
//
// The central type is [Cube], a cubie-level state (corner and edge
// permutation and orientation) that is cheap to copy and to turn. Turns are
// described by the [Move] type, which has a text notation ("R", "R'", "R2")
// handled by [ParseMoves] and [FormatMoves]. A facelet view of the cube
// (54 stickers, laid out as in the unfolded net below) can be converted to
// and from a [Cube] with [FromFacelets] and [Cube.Facelets].
//
// # Facelets
//
// Each face has nine stickers numbered 1-9 in reading order, seen from
// outside the cube, with the net laid out as
//
//	          U1 U2 U3
//	          U4 U5 U6
//	          U7 U8 U9
//	L1 L2 L3  F1 F2 F3  R1 R2 R3  B1 B2 B3
//	L4 L5 L6  F4 F5 F6  R4 R5 R6  B4 B5 B6
//	L7 L8 L9  F7 F8 F9  R7 R8 R9  B7 B8 B9
//	          D1 D2 D3
//	          D4 D5 D6
//	          D7 D8 D9
//
// A facelet string lists the faces in the order U, R, F, D, L, B and the
// stickers of each face in numerical order; every character is the letter of
// the face whose centre has that sticker's colour. The solved cube is
// "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB".
//
// # Cubie conventions
//
// Corner positions are URF, UFL, ULB, UBR, DFR, DLF, DBL, DRB and edge
// positions are UR, UF, UL, UB, DR, DF, DL, DB, FR, FL, BL, BR. A corner's
// orientation is the index (0-2, clockwise) of the facelet within its
// position that carries the piece's U/D sticker. An edge's orientation is 0
// when its first facelet (the U/D facelet, or for the four middle-layer
// edges the F/B facelet) shows the piece's first colour. With these
// conventions only quarter turns of F and B change edge orientation.
package cube
