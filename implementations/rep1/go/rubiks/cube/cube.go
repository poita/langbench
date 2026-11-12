package cube

import "errors"

// Slot and piece counts.
const (
	NumCorners = 8
	NumEdges   = 12
)

// Corner slot/piece indices.
const (
	URF = iota
	UFL
	ULB
	UBR
	DFR
	DLF
	DBL
	DRB
)

// Edge slot/piece indices.
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
)

// Cube is a cube state at the cubie level.
//
// CP[i] is the corner piece sitting in corner slot i and CO[i] its twist
// (0, 1 or 2); EP[i] is the edge piece in edge slot i and EO[i] its flip
// (0 or 1). See the package documentation for the orientation conventions.
// The zero value is not a valid cube; use [Solved].
type Cube struct {
	CP [NumCorners]uint8
	CO [NumCorners]uint8
	EP [NumEdges]uint8
	EO [NumEdges]uint8
}

// Solved returns the solved cube.
func Solved() Cube {
	var c Cube
	for i := range c.CP {
		c.CP[i] = uint8(i)
	}
	for i := range c.EP {
		c.EP[i] = uint8(i)
	}
	return c
}

// IsSolved reports whether c is the solved cube.
func (c Cube) IsSolved() bool { return c == Solved() }

// Mul returns the cube obtained by taking c and then applying to it the
// permutation that b represents (b is read as "the effect of a move
// sequence on a solved cube").
func (c Cube) Mul(b Cube) Cube {
	var r Cube
	for i := 0; i < NumCorners; i++ {
		j := b.CP[i]
		r.CP[i] = c.CP[j]
		r.CO[i] = (c.CO[j] + b.CO[i]) % 3
	}
	for i := 0; i < NumEdges; i++ {
		j := b.EP[i]
		r.EP[i] = c.EP[j]
		r.EO[i] = c.EO[j] ^ b.EO[i]
	}
	return r
}

// Apply turns the cube by m.
func (c *Cube) Apply(m Move) { *c = c.Mul(moveCubes[m]) }

// ApplyAll turns the cube by every move of seq in order.
func (c *Cube) ApplyAll(seq []Move) {
	for _, m := range seq {
		*c = c.Mul(moveCubes[m])
	}
}

// MoveCube returns the state reached by applying m to a solved cube.
func MoveCube(m Move) Cube { return moveCubes[m] }

// Validate reports whether c is a state reachable from the solved cube by
// legal turns: pieces form permutations, corner twists sum to 0 mod 3, edge
// flips sum to 0 mod 2, and corner and edge permutation parities agree.
func (c Cube) Validate() error {
	var seenC, seenE uint16
	cornerTwist := 0
	for i := 0; i < NumCorners; i++ {
		if c.CP[i] >= NumCorners || c.CO[i] > 2 {
			return errors.New("cube: corner out of range")
		}
		seenC |= 1 << c.CP[i]
		cornerTwist += int(c.CO[i])
	}
	edgeFlip := 0
	for i := 0; i < NumEdges; i++ {
		if c.EP[i] >= NumEdges || c.EO[i] > 1 {
			return errors.New("cube: edge out of range")
		}
		seenE |= 1 << c.EP[i]
		edgeFlip += int(c.EO[i])
	}
	switch {
	case seenC != 1<<NumCorners-1:
		return errors.New("cube: corner pieces are not a permutation")
	case seenE != 1<<NumEdges-1:
		return errors.New("cube: edge pieces are not a permutation")
	case cornerTwist%3 != 0:
		return errors.New("cube: corner twist is not a multiple of three")
	case edgeFlip%2 != 0:
		return errors.New("cube: edge flip parity is odd")
	case permParity(c.CP[:]) != permParity(c.EP[:]):
		return errors.New("cube: corner and edge permutation parities differ")
	}
	return nil
}

// permParity returns 0 for even permutations and 1 for odd ones.
func permParity(p []uint8) int {
	n := 0
	for i := range p {
		for j := i + 1; j < len(p); j++ {
			if p[i] > p[j] {
				n++
			}
		}
	}
	return n & 1
}
