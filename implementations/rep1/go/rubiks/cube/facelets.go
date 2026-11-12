package cube

import (
	"fmt"
	"strings"
)

// NumFacelets is the number of stickers on the cube.
const NumFacelets = 54

// facelet returns the index of a sticker name such as "U7" (face letter and
// number 1-9): face*9 + n-1 with faces ordered U R F D L B.
func facelet(name string) int {
	return strings.IndexByte(faceLetters, name[0])*9 + int(name[1]-'1')
}

func faceletList(names string) []int {
	var out []int
	for _, n := range strings.Fields(names) {
		out = append(out, facelet(n))
	}
	return out
}

// cornerFacelets[i] lists the three stickers of corner slot i, starting with
// its U or D sticker and continuing clockwise around the corner.
var cornerFacelets = [NumCorners][3]int{}

// edgeFacelets[i] lists the two stickers of edge slot i.
var edgeFacelets = [NumEdges][2]int{}

// moveCycles gives, for each face, the facelet 4-cycles of its clockwise
// quarter turn: the sticker at a moves to b, b to c, c to d and d to a.
var moveCycles = [6]string{
	U: "U1 U3 U9 U7, U2 U6 U8 U4, F1 L1 B1 R1, F2 L2 B2 R2, F3 L3 B3 R3",
	R: "R1 R3 R9 R7, R2 R6 R8 R4, F3 U3 B7 D3, F6 U6 B4 D6, F9 U9 B1 D9",
	F: "F1 F3 F9 F7, F2 F6 F8 F4, U7 R1 D3 L9, U8 R4 D2 L6, U9 R7 D1 L3",
	D: "D1 D3 D9 D7, D2 D6 D8 D4, F7 R7 B7 L7, F8 R8 B8 L8, F9 R9 B9 L9",
	L: "L1 L3 L9 L7, L2 L6 L8 L4, F1 D1 B9 U1, F4 D4 B6 U4, F7 D7 B3 U7",
	B: "B1 B3 B9 B7, B2 B6 B8 B4, U3 L1 D7 R9, U2 L4 D8 R6, U1 L7 D9 R3",
}

// moveCubes[m] is the cubie-level effect of each move on a solved cube.
var moveCubes [NumMoves]Cube

func init() {
	for i, names := range []string{
		"U9 R1 F3", "U7 F1 L3", "U1 L1 B3", "U3 B1 R3",
		"D3 F9 R7", "D1 L9 F7", "D7 B9 L7", "D9 R9 B7",
	} {
		copy(cornerFacelets[i][:], faceletList(names))
	}
	for i, names := range []string{
		"U6 R2", "U8 F2", "U4 L2", "U2 B2", "D6 R8", "D2 F8", "D4 L8", "D8 B8",
		"F6 R4", "F4 L6", "B6 L4", "B4 R6",
	} {
		copy(edgeFacelets[i][:], faceletList(names))
	}

	for f := Face(U); f <= B; f++ {
		// Apply the face's cycles to a solved sticker array.
		var s [NumFacelets]byte
		for i := range s {
			s[i] = faceLetters[i/9]
		}
		old := s
		for _, cyc := range strings.Split(moveCycles[f], ",") {
			p := faceletList(cyc)
			for k := range p {
				s[p[(k+1)%4]] = old[p[k]]
			}
		}
		c, err := FromFacelets(string(s[:]))
		if err != nil {
			panic(err)
		}
		q := c
		moveCubes[3*int(f)] = q
		q = q.Mul(c)
		moveCubes[3*int(f)+1] = q
		q = q.Mul(c)
		moveCubes[3*int(f)+2] = q
	}
}

// Facelets returns the 54 stickers of c as face letters, in the order
// U1..U9, R1..R9, F1..F9, D1..D9, L1..L9, B1..B9. A solved cube is
// "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB".
func (c Cube) Facelets() string {
	var s [NumFacelets]byte
	for i := range s {
		s[i] = faceLetters[i/9] // centres
	}
	for i := 0; i < NumCorners; i++ {
		piece := c.CP[i]
		for k := 0; k < 3; k++ {
			s[cornerFacelets[i][(k+int(c.CO[i]))%3]] = faceLetters[cornerFacelets[piece][k]/9]
		}
	}
	for i := 0; i < NumEdges; i++ {
		piece := c.EP[i]
		for k := 0; k < 2; k++ {
			s[edgeFacelets[i][(k+int(c.EO[i]))%2]] = faceLetters[edgeFacelets[piece][k]/9]
		}
	}
	return string(s[:])
}

// FromFacelets builds a cube from a 54-letter sticker string (see
// [Cube.Facelets]). It returns an error if the stickers do not describe a
// physically assembled cube; it does not check solvability beyond what
// that implies, so call [Cube.Validate] on the result if you need it.
func FromFacelets(s string) (Cube, error) {
	var c Cube
	if len(s) != NumFacelets {
		return c, fmt.Errorf("cube: need %d facelets, got %d", NumFacelets, len(s))
	}
	for i := 0; i < NumFacelets; i++ {
		if strings.IndexByte(faceLetters, s[i]) < 0 {
			return c, fmt.Errorf("cube: invalid facelet %q", s[i])
		}
	}
	for i := 0; i < NumCorners; i++ {
		var col [3]byte
		for k := 0; k < 3; k++ {
			col[k] = s[cornerFacelets[i][k]]
		}
		o := -1
		for k := 0; k < 3; k++ {
			if col[k] == 'U' || col[k] == 'D' {
				o = k
				break
			}
		}
		found := false
		if o >= 0 {
			for j := 0; j < NumCorners && !found; j++ {
				if faceLetters[cornerFacelets[j][0]/9] == col[o] &&
					faceLetters[cornerFacelets[j][1]/9] == col[(o+1)%3] &&
					faceLetters[cornerFacelets[j][2]/9] == col[(o+2)%3] {
					c.CP[i], c.CO[i] = uint8(j), uint8(o)
					found = true
				}
			}
		}
		if !found {
			return c, fmt.Errorf("cube: invalid corner at slot %d", i)
		}
	}
	for i := 0; i < NumEdges; i++ {
		a, b := s[edgeFacelets[i][0]], s[edgeFacelets[i][1]]
		found := false
		for j := 0; j < NumEdges && !found; j++ {
			ja := faceLetters[edgeFacelets[j][0]/9]
			jb := faceLetters[edgeFacelets[j][1]/9]
			switch {
			case a == ja && b == jb:
				c.EP[i], c.EO[i] = uint8(j), 0
				found = true
			case a == jb && b == ja:
				c.EP[i], c.EO[i] = uint8(j), 1
				found = true
			}
		}
		if !found {
			return c, fmt.Errorf("cube: invalid edge at slot %d", i)
		}
	}
	return c, nil
}
