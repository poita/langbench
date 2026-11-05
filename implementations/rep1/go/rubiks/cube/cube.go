package cube

import (
	"errors"
	"fmt"
)

// Corner positions (and pieces), in the order used by [Cube.CP].
const (
	URF = iota
	UFL
	ULB
	UBR
	DFR
	DLF
	DBL
	DRB
	NumCorners
)

// Edge positions (and pieces), in the order used by [Cube.EP].
const (
	UR = iota
	UF
	UL
	UB
	DR
	DF
	DL
	DB
	FR
	FL
	BL
	BR
	NumEdges
)

// Cube is a cubie-level state of a 3x3x3 cube.
//
// CP[i] is the corner piece sitting at corner position i and CO[i] its
// orientation (0-2); EP[i] and EO[i] are the same for edges (orientation 0-1).
// Pieces are numbered like the positions they occupy on the solved cube. See
// the package documentation for the orientation conventions.
//
// The zero value is not a valid cube; use [New]. Cube is a small value type
// and is copied by assignment.
type Cube struct {
	CP [NumCorners]uint8
	CO [NumCorners]uint8
	EP [NumEdges]uint8
	EO [NumEdges]uint8
}

// New returns the solved cube.
func New() Cube {
	var c Cube
	for i := range c.CP {
		c.CP[i] = uint8(i)
	}
	for i := range c.EP {
		c.EP[i] = uint8(i)
	}
	return c
}

// IsSolved reports whether the cube is solved.
func (c Cube) IsSolved() bool { return c == New() }

// Compose returns the cube obtained by applying the permutation described by
// a and then the one described by b. Moves are cubes too: Compose(c,
// MoveCube(m)) is c followed by m.
func Compose(a, b *Cube) Cube {
	var r Cube
	for i := 0; i < NumCorners; i++ {
		j := b.CP[i]
		r.CP[i] = a.CP[j]
		o := a.CO[j] + b.CO[i]
		if o >= 3 {
			o -= 3
		}
		r.CO[i] = o
	}
	for i := 0; i < NumEdges; i++ {
		j := b.EP[i]
		r.EP[i] = a.EP[j]
		r.EO[i] = a.EO[j] ^ b.EO[i]
	}
	return r
}

// MoveCube returns the cubie state produced by applying m to a solved cube.
// The returned pointer refers to shared data and must not be modified.
func MoveCube(m Move) *Cube { return &moveCubes[m] }

// Apply turns the cube by m.
func (c *Cube) Apply(m Move) { *c = Compose(c, &moveCubes[m]) }

// ApplyAll applies the moves in order.
func (c *Cube) ApplyAll(moves []Move) {
	for _, m := range moves {
		*c = Compose(c, &moveCubes[m])
	}
}

// Then returns the cube after applying m, leaving c unchanged.
func (c Cube) Then(m Move) Cube { return Compose(&c, &moveCubes[m]) }

// Scrambled returns a solved cube with moves applied.
func Scrambled(moves []Move) Cube {
	c := New()
	c.ApplyAll(moves)
	return c
}

// Inverse returns the cube that, composed with c, gives the solved cube.
func (c Cube) Inverse() Cube {
	var r Cube
	for i := 0; i < NumCorners; i++ {
		p := c.CP[i]
		r.CP[p] = uint8(i)
		r.CO[p] = (3 - c.CO[i]) % 3
	}
	for i := 0; i < NumEdges; i++ {
		p := c.EP[i]
		r.EP[p] = uint8(i)
		r.EO[p] = c.EO[i]
	}
	return r
}

// Verify checks that the cube is a reachable state: valid permutations,
// corner twists summing to 0 mod 3, edge flips summing to 0 mod 2, and equal
// corner and edge permutation parity.
func (c Cube) Verify() error {
	var seenC, seenE uint16
	twist, flip := 0, 0
	for i := 0; i < NumCorners; i++ {
		if c.CP[i] >= NumCorners || c.CO[i] >= 3 {
			return fmt.Errorf("cube: corner %d out of range", i)
		}
		seenC |= 1 << c.CP[i]
		twist += int(c.CO[i])
	}
	for i := 0; i < NumEdges; i++ {
		if c.EP[i] >= NumEdges || c.EO[i] >= 2 {
			return fmt.Errorf("cube: edge %d out of range", i)
		}
		seenE |= 1 << c.EP[i]
		flip += int(c.EO[i])
	}
	if seenC != 1<<NumCorners-1 {
		return errors.New("cube: corners are not a permutation")
	}
	if seenE != 1<<NumEdges-1 {
		return errors.New("cube: edges are not a permutation")
	}
	if twist%3 != 0 {
		return errors.New("cube: corner twist is not a multiple of 3")
	}
	if flip%2 != 0 {
		return errors.New("cube: edge flip is odd")
	}
	if parity(c.CP[:]) != parity(c.EP[:]) {
		return errors.New("cube: corner and edge permutation parities differ")
	}
	return nil
}

// parity returns the parity (0 even, 1 odd) of a permutation.
func parity(p []uint8) int {
	inv := 0
	for i := range p {
		for j := i + 1; j < len(p); j++ {
			if p[i] > p[j] {
				inv++
			}
		}
	}
	return inv & 1
}
