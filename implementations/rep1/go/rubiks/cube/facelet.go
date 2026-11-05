package cube

import (
	"errors"
	"fmt"
	"strings"
)

// NumFacelets is the number of stickers on the cube.
const NumFacelets = 54

// SolvedFacelets is the facelet string of the solved cube.
const SolvedFacelets = "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB"

// FaceletIndex returns the index into a facelet string of the sticker named
// like "U1", "F9" or "B5".
func FaceletIndex(name string) (int, error) {
	if len(name) != 2 || name[1] < '1' || name[1] > '9' {
		return 0, fmt.Errorf("cube: invalid facelet name %q", name)
	}
	f := strings.IndexByte("URFDLB", name[0])
	if f < 0 {
		return 0, fmt.Errorf("cube: invalid facelet name %q", name)
	}
	return f*9 + int(name[1]-'1'), nil
}

func mustFacelet(name string) int {
	i, err := FaceletIndex(name)
	if err != nil {
		panic(err)
	}
	return i
}

func faceletList(names ...string) []int {
	out := make([]int, len(names))
	for i, n := range names {
		out[i] = mustFacelet(n)
	}
	return out
}

// cornerFacelets[i] lists the facelets of corner position i, clockwise,
// starting with the U/D facelet. edgeFacelets[i] likewise for edges, starting
// with the U/D facelet (F/B for the middle layer).
var (
	cornerFacelets [NumCorners][3]int
	edgeFacelets   [NumEdges][2]int
)

// cornerColors[p] and edgeColors[p] are the face colours of piece p's
// stickers when it sits solved, in the order of the facelet lists above.
var (
	cornerColors [NumCorners][3]uint8
	edgeColors   [NumEdges][2]uint8
)

// moveCycles are the facelet cycles that define the six clockwise quarter
// turns; the sticker at the first facelet of a cycle moves to the second, and
// so on.
var moveCycles = [NumFaces]string{
	U: "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
	R: "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
	F: "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
	D: "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
	L: "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
	B: "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)",
}

// moveCubes[m] is the cubie state of a solved cube after move m.
var moveCubes [NumMoves]Cube

func init() {
	for i, s := range [NumCorners]string{
		"U9 R1 F3", "U7 F1 L3", "U1 L1 B3", "U3 B1 R3",
		"D3 F9 R7", "D1 L9 F7", "D7 B9 L7", "D9 R9 B7",
	} {
		copy(cornerFacelets[i][:], faceletList(strings.Fields(s)...))
		for k, f := range cornerFacelets[i] {
			cornerColors[i][k] = uint8(f / 9)
		}
	}
	for i, s := range [NumEdges]string{
		"U6 R2", "U8 F2", "U4 L2", "U2 B2", "D6 R8", "D2 F8",
		"D4 L8", "D8 B8", "F6 R4", "F4 L6", "B6 L4", "B4 R6",
	} {
		copy(edgeFacelets[i][:], faceletList(strings.Fields(s)...))
		for k, f := range edgeFacelets[i] {
			edgeColors[i][k] = uint8(f / 9)
		}
	}

	// Derive each move's cubie state by turning a facelet-level solved cube.
	for f := Face(0); f < NumFaces; f++ {
		var cycles [][]int
		for _, part := range strings.Split(strings.Trim(moveCycles[f], "()"), ")(") {
			cycles = append(cycles, faceletList(strings.Fields(part)...))
		}
		var state [NumFacelets]uint8
		for i := range state {
			state[i] = uint8(i / 9)
		}
		next := state
		for _, cy := range cycles {
			for k, a := range cy {
				next[cy[(k+1)%len(cy)]] = state[a]
			}
		}
		quarter, err := fromColors(next)
		if err != nil {
			panic("cube: bad move definition: " + err.Error())
		}
		moveCubes[NewMove(f, 1)] = quarter
	}
	for f := Face(0); f < NumFaces; f++ {
		q := moveCubes[NewMove(f, 1)]
		h := Compose(&q, &q)
		moveCubes[NewMove(f, 2)] = h
		moveCubes[NewMove(f, 3)] = Compose(&h, &q)
	}
}

// Facelets returns the 54-character facelet string of the cube (see the
// package documentation).
func (c Cube) Facelets() string {
	var out [NumFacelets]byte
	for i := 0; i < NumCorners; i++ {
		p, o := c.CP[i], int(c.CO[i])
		for k := 0; k < 3; k++ {
			out[cornerFacelets[i][(k+o)%3]] = "URFDLB"[cornerColors[p][k]]
		}
	}
	for i := 0; i < NumEdges; i++ {
		p, o := c.EP[i], int(c.EO[i])
		for k := 0; k < 2; k++ {
			out[edgeFacelets[i][(k+o)%2]] = "URFDLB"[edgeColors[p][k]]
		}
	}
	// Centres never move.
	for f := 0; f < NumFaces; f++ {
		out[f*9+4] = "URFDLB"[f]
	}
	return string(out[:])
}

// FromFacelets builds a cube from a 54-character facelet string. It returns
// an error if the string is not a physically consistent cube state: wrong
// length or characters, centres not in URFDLB order, a corner or edge that
// does not exist, a piece used twice, or a state that cannot be reached by
// legal turns (see [Cube.Verify]).
func FromFacelets(s string) (Cube, error) {
	if len(s) != NumFacelets {
		return Cube{}, fmt.Errorf("cube: facelet string has %d characters, want %d", len(s), NumFacelets)
	}
	var colors [NumFacelets]uint8
	for i := 0; i < NumFacelets; i++ {
		f := strings.IndexByte("URFDLB", s[i])
		if f < 0 {
			return Cube{}, fmt.Errorf("cube: invalid facelet character %q", s[i])
		}
		colors[i] = uint8(f)
	}
	for f := 0; f < NumFaces; f++ {
		if int(colors[f*9+4]) != f {
			return Cube{}, errors.New("cube: centre facelets must be in URFDLB order")
		}
	}
	c, err := fromColors(colors)
	if err != nil {
		return Cube{}, err
	}
	if err := c.Verify(); err != nil {
		return Cube{}, err
	}
	return c, nil
}

// fromColors identifies the cubies in a colour assignment. It does not check
// global solvability.
func fromColors(col [NumFacelets]uint8) (Cube, error) {
	var c Cube
	var usedC, usedE uint16
	for i := 0; i < NumCorners; i++ {
		o := 0
		for o < 3 && col[cornerFacelets[i][o]] != uint8(U) && col[cornerFacelets[i][o]] != uint8(D) {
			o++
		}
		if o == 3 {
			return c, fmt.Errorf("cube: corner %d has no U or D sticker", i)
		}
		c1 := col[cornerFacelets[i][(o+1)%3]]
		c2 := col[cornerFacelets[i][(o+2)%3]]
		c0 := col[cornerFacelets[i][o]]
		found := false
		for p := 0; p < NumCorners; p++ {
			if cornerColors[p] == [3]uint8{c0, c1, c2} {
				c.CP[i], c.CO[i] = uint8(p), uint8(o)
				usedC |= 1 << p
				found = true
				break
			}
		}
		if !found {
			return c, fmt.Errorf("cube: corner %d has an impossible colour combination", i)
		}
	}
	for i := 0; i < NumEdges; i++ {
		c0, c1 := col[edgeFacelets[i][0]], col[edgeFacelets[i][1]]
		found := false
		for p := 0; p < NumEdges; p++ {
			switch edgeColors[p] {
			case [2]uint8{c0, c1}:
				c.EP[i], c.EO[i] = uint8(p), 0
				found = true
			case [2]uint8{c1, c0}:
				c.EP[i], c.EO[i] = uint8(p), 1
				found = true
			}
			if found {
				usedE |= 1 << p
				break
			}
		}
		if !found {
			return c, fmt.Errorf("cube: edge %d has an impossible colour combination", i)
		}
	}
	if usedC != 1<<NumCorners-1 || usedE != 1<<NumEdges-1 {
		return c, errors.New("cube: a corner or edge appears more than once")
	}
	return c, nil
}
