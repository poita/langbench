package solver

import (
	"rubiks/cube"
)

const (
	numFlip     = 1 << 11 // orientations of 11 edges
	numTwist    = 2187    // 3^7 orientations of 7 corners
	numSlice    = 495     // C(12,4) positions of the E-slice edges
	numCorner96 = 96      // corner permutations in the half-turn group
	numClass    = 420     // 8!/96 cosets of the half-turn corner group
	numMask8    = 70      // C(8,4) positions of M-slice edges among 8
	numEdgePerm = 24 * 24 * 24
	unvisited   = 255
)

// component is one factor of a phase coordinate together with its move table:
// move[v*cube.NumMoves+m] is the value after applying move m to value v.
// Entries for moves outside the phase's move set are left zero.
type component struct {
	size int
	move []uint16
}

// phase is a stage of the algorithm. Its coordinate is a*b.size + b over the
// product of two components; dist holds the exact distance to goal.
type phase struct {
	moves []cube.Move
	a, b  component
	goal  int
	dist  []uint8
}

// tables holds everything built at start-up.
type tables struct {
	slice12 *subsetIndex // 12-bit masks with 4 bits set
	mask8   *subsetIndex // 8-bit masks with 4 bits set

	// Corner permutations: rank -> index in the half-turn group (or -1) and
	// rank -> coset class; halfPerms and classRep list the members.
	halfIdx   []int16
	classOf   []int16
	halfPerms [numCorner96][8]uint8
	classRep  [numClass][8]uint8

	phases [4]phase
}

func newTables() *tables {
	t := &tables{
		slice12: newSubsetIndex(12, 4),
		mask8:   newSubsetIndex(8, 4),
	}
	t.buildCornerTables()
	t.buildPhases()
	return t
}

// ---- coordinates of a cube state --------------------------------------

// edge slices: S = even edges below 8 (UR UL DR DL), M = odd edges below 8
// (UF UB DF DB), E = edges 8..11. Local position/piece number within a slice:
func edgeSlice(e uint8) int {
	if e >= 8 {
		return 2
	}
	return int(e & 1) // 0 = S, 1 = M
}

func edgeLocal(e uint8) uint8 {
	if e >= 8 {
		return e - 8
	}
	return e >> 1
}

func coordFlip(c *cube.Cube) int {
	v := 0
	for i := 0; i < 11; i++ {
		v |= int(c.EO[i]) << i
	}
	return v
}

func coordTwist(c *cube.Cube) int {
	v := 0
	for i := 0; i < 7; i++ {
		v = v*3 + int(c.CO[i])
	}
	return v
}

func (t *tables) coordSlice(c *cube.Cube) int {
	m := 0
	for i, e := range c.EP {
		if e >= 8 {
			m |= 1 << i
		}
	}
	return int(t.slice12.rank[m])
}

func (t *tables) coordClass(c *cube.Cube) int { return int(t.classOf[rankPerm(c.CP[:])]) }

// coordMask8 locates the M-slice edges among the eight U/D-layer positions.
// It is only meaningful when the E-slice edges are in the E slice.
func (t *tables) coordMask8(c *cube.Cube) int {
	m := 0
	for i := 0; i < 8; i++ {
		if c.EP[i]&1 == 1 {
			m |= 1 << i
		}
	}
	return int(t.mask8.rank[m])
}

func (t *tables) coordCorner96(c *cube.Cube) int { return int(t.halfIdx[rankPerm(c.CP[:])]) }

// coordEdgePerm ranks the permutation of each slice within its own positions.
// It is only meaningful when every edge is in its own slice.
func coordEdgePerm(c *cube.Cube) int {
	var p [3][4]uint8
	for pos, e := range c.EP {
		p[edgeSlice(uint8(pos))][edgeLocal(uint8(pos))] = edgeLocal(e)
	}
	return (rankPerm4(p[0])*24+rankPerm4(p[1]))*24 + rankPerm4(p[2])
}

// ---- corner tables -----------------------------------------------------

func (t *tables) buildCornerTables() {
	const n = 40320
	// The half-turn corner group: closure of the identity under half turns.
	t.halfIdx = make([]int16, n)
	for i := range t.halfIdx {
		t.halfIdx[i] = -1
	}
	var halfMoves []*cube.Cube
	for f := cube.Face(0); f < cube.NumFaces; f++ {
		halfMoves = append(halfMoves, cube.MoveCube(cube.NewMove(f, 2)))
	}
	count := 0
	var id [8]uint8
	for i := range id {
		id[i] = uint8(i)
	}
	t.halfPerms[0] = id
	t.halfIdx[0] = 0
	count = 1
	for head := 0; head < count; head++ {
		cur := t.halfPerms[head]
		for _, m := range halfMoves {
			var nxt [8]uint8
			for c := range nxt {
				nxt[c] = cur[m.CP[c]]
			}
			r := rankPerm(nxt[:])
			if t.halfIdx[r] < 0 {
				t.halfIdx[r] = int16(count)
				t.halfPerms[count] = nxt
				count++
			}
		}
	}
	if count != numCorner96 {
		panic("solver: half-turn corner group has wrong order")
	}

	// Classes: orbits of corner permutations under relabelling pieces by the
	// group, s -> h∘s (so that class(s∘move) depends only on class(s)).
	t.classOf = make([]int16, n)
	for i := range t.classOf {
		t.classOf[i] = -1
	}
	classes := 0
	var s, u [8]uint8
	for r := 0; r < n; r++ {
		if t.classOf[r] >= 0 {
			continue
		}
		unrankPerm(r, s[:])
		t.classRep[classes] = s
		for _, h := range t.halfPerms {
			for i := range u {
				u[i] = h[s[i]]
			}
			t.classOf[rankPerm(u[:])] = int16(classes)
		}
		classes++
	}
	if classes != numClass {
		panic("solver: wrong number of corner classes")
	}
}

// ---- move tables -------------------------------------------------------

// buildComponent makes a move table by decoding each value to a
// representative cube, applying each move once and re-encoding.
func buildComponent(size int, moves []cube.Move, decode func(v int) cube.Cube, encode func(c *cube.Cube) int) component {
	comp := component{size: size, move: make([]uint16, size*cube.NumMoves)}
	for v := 0; v < size; v++ {
		base := decode(v)
		for _, m := range moves {
			next := cube.Compose(&base, cube.MoveCube(m))
			comp.move[v*cube.NumMoves+int(m)] = uint16(encode(&next))
		}
	}
	return comp
}

func (t *tables) buildPhases() {
	all := make([]cube.Move, cube.NumMoves)
	for i := range all {
		all[i] = cube.Move(i)
	}
	var p2, p3, p4 []cube.Move
	for m := cube.Move(0); m < cube.NumMoves; m++ {
		f := m.Face()
		if !((f == cube.F || f == cube.B) && !m.IsHalfTurn()) {
			p2 = append(p2, m)
		}
		if f == cube.U || f == cube.D || m.IsHalfTurn() {
			p3 = append(p3, m)
		}
		if m.IsHalfTurn() {
			p4 = append(p4, m)
		}
	}

	unit := component{size: 1, move: make([]uint16, cube.NumMoves)}

	// Phase 1: edge orientation.
	flip := buildComponent(numFlip, all,
		func(v int) cube.Cube {
			c := cube.New()
			sum := 0
			for i := 0; i < 11; i++ {
				c.EO[i] = uint8(v >> i & 1)
				sum += int(c.EO[i])
			}
			c.EO[11] = uint8(sum & 1)
			return c
		},
		func(c *cube.Cube) int { return coordFlip(c) })
	t.phases[0] = phase{moves: all, a: flip, b: unit, goal: 0}

	// Phase 2: corner orientation and E-slice edge positions.
	twist := buildComponent(numTwist, p2,
		func(v int) cube.Cube {
			c := cube.New()
			sum := 0
			for i := 6; i >= 0; i-- {
				c.CO[i] = uint8(v % 3)
				sum += int(c.CO[i])
				v /= 3
			}
			c.CO[7] = uint8((3 - sum%3) % 3)
			return c
		},
		func(c *cube.Cube) int { return coordTwist(c) })
	slice := buildComponent(numSlice, p2,
		func(v int) cube.Cube {
			c := cube.New()
			mask := int(t.slice12.mask[v])
			lo, hi := uint8(0), uint8(8)
			for i := 0; i < 12; i++ {
				if mask>>i&1 == 1 {
					c.EP[i] = hi
					hi++
				} else {
					c.EP[i] = lo
					lo++
				}
			}
			return c
		},
		func(c *cube.Cube) int { return t.coordSlice(c) })
	t.phases[1] = phase{moves: p2, a: twist, b: slice, goal: 0*numSlice + int(t.slice12.rank[0xF00])}

	// Phase 3: corner class and M-slice edge positions among the U/D layers.
	class := buildComponent(numClass, p3,
		func(v int) cube.Cube {
			c := cube.New()
			c.CP = t.classRep[v]
			return c
		},
		func(c *cube.Cube) int { return t.coordClass(c) })
	mask8 := buildComponent(numMask8, p3,
		func(v int) cube.Cube {
			c := cube.New()
			mask := int(t.mask8.mask[v])
			even, odd := uint8(0), uint8(1)
			for i := 0; i < 8; i++ {
				if mask>>i&1 == 1 {
					c.EP[i] = odd
					odd += 2
				} else {
					c.EP[i] = even
					even += 2
				}
			}
			return c
		},
		func(c *cube.Cube) int { return t.coordMask8(c) })
	t.phases[2] = phase{moves: p3, a: class, b: mask8, goal: 0*numMask8 + int(t.mask8.rank[0xAA])}

	// Phase 4: corner permutation within the half-turn group and the
	// permutation of each edge slice.
	corner := buildComponent(numCorner96, p4,
		func(v int) cube.Cube {
			c := cube.New()
			c.CP = t.halfPerms[v]
			return c
		},
		func(c *cube.Cube) int { return t.coordCorner96(c) })
	edgePerm := buildComponent(numEdgePerm, p4,
		func(v int) cube.Cube {
			c := cube.New()
			var ranks [3]int
			ranks[2], ranks[1], ranks[0] = v%24, v/24%24, v/576
			var local [4]uint8
			for s := 0; s < 3; s++ {
				unrankPerm(ranks[s], local[:])
				for i := 0; i < 4; i++ {
					pos := slicePos(s, i)
					c.EP[pos] = slicePos(s, int(local[i]))
				}
			}
			return c
		},
		func(c *cube.Cube) int { return coordEdgePerm(c) })
	t.phases[3] = phase{moves: p4, a: corner, b: edgePerm, goal: 0}

	for i := range t.phases {
		t.phases[i].bfs()
	}
}

// slicePos is the edge number at local index i of slice s (0 = S, 1 = M, 2 = E).
func slicePos(s, i int) uint8 {
	if s == 2 {
		return uint8(8 + i)
	}
	return uint8(2*i + s)
}

// bfs fills p.dist with exact distances to the goal. All phase move sets are
// closed under inverses, so distance from the goal equals distance to it.
func (p *phase) bfs() {
	nb := p.b.size
	total := p.a.size * nb
	p.dist = make([]uint8, total)
	for i := range p.dist {
		p.dist[i] = unvisited
	}
	queue := make([]uint32, 0, total)
	p.dist[p.goal] = 0
	queue = append(queue, uint32(p.goal))
	const nm = cube.NumMoves
	for head := 0; head < len(queue); head++ {
		idx := int(queue[head])
		a, b := idx/nb, idx%nb
		d := p.dist[idx] + 1
		abase, bbase := a*nm, b*nm
		for _, m := range p.moves {
			next := int(p.a.move[abase+int(m)])*nb + int(p.b.move[bbase+int(m)])
			if p.dist[next] == unvisited {
				p.dist[next] = d
				queue = append(queue, uint32(next))
			}
		}
	}
}

// descend appends to out the moves of an optimal path from coordinate (a, b)
// to the goal, and returns the extended slice and the final coordinates (which
// are those of the goal). ok is false if the state is not connected to the
// goal.
func (p *phase) descend(a, b int, out []cube.Move) ([]cube.Move, bool) {
	nb := p.b.size
	const nm = cube.NumMoves
	d := p.dist[a*nb+b]
	if d == unvisited {
		return out, false
	}
	for d > 0 {
		moved := false
		for _, m := range p.moves {
			na := int(p.a.move[a*nm+int(m)])
			nbv := int(p.b.move[b*nm+int(m)])
			if p.dist[na*nb+nbv] == d-1 {
				a, b = na, nbv
				out = append(out, m)
				d--
				moved = true
				break
			}
		}
		if !moved {
			return out, false
		}
	}
	return out, true
}
