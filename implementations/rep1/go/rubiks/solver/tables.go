package solver

import "example.com/rubiks/cube"

// The move sets of the four phases.
var (
	phase1Moves = allMoves()
	phase2Moves = movesWhere(func(m cube.Move) bool {
		f := m.Face()
		return !((f == cube.F || f == cube.B) && m.Turns() != 2)
	})
	phase3Moves = movesWhere(func(m cube.Move) bool {
		f := m.Face()
		return f == cube.U || f == cube.D || m.Turns() == 2
	})
	phase4Moves = movesWhere(func(m cube.Move) bool { return m.Turns() == 2 })
)

func allMoves() []cube.Move { return movesWhere(func(cube.Move) bool { return true }) }

func movesWhere(keep func(cube.Move) bool) []cube.Move {
	var out []cube.Move
	for m := cube.Move(0); m < cube.NumMoves; m++ {
		if keep(m) {
			out = append(out, m)
		}
	}
	return out
}

// moveTable[x][i] is the coordinate reached from x by the i-th move of a
// phase's move set.
type moveTable [][]int32

// buildMoveTable tabulates the action of moves on n coordinate values, using
// a representative cube for each value.
func buildMoveTable(n int, moves []cube.Move, rep func(int) cube.Cube, coord func(*cube.Cube) int) moveTable {
	t := make(moveTable, n)
	flat := make([]int32, n*len(moves))
	for x := 0; x < n; x++ {
		t[x] = flat[x*len(moves) : (x+1)*len(moves)]
		base := rep(x)
		for i, m := range moves {
			c := base.Mul(cube.MoveCube(m))
			t[x][i] = int32(coord(&c))
		}
	}
	return t
}

// bfs fills the exact distance of every state from goal, using the move
// graph given by next. The move sets are closed under inversion, so the
// graph is undirected and searching forward from the goal is exact. States
// that cannot be reached keep the distance -1.
func bfs(size, goal, nMoves int, next func(state, move int) int) []int8 {
	dist := make([]int8, size)
	for i := range dist {
		dist[i] = -1
	}
	dist[goal] = 0
	queue := make([]int32, 1, 1024)
	queue[0] = int32(goal)
	for head := 0; head < len(queue); head++ {
		s := int(queue[head])
		d := dist[s] + 1
		for m := 0; m < nMoves; m++ {
			n := next(s, m)
			if dist[n] < 0 {
				dist[n] = d
				queue = append(queue, int32(n))
			}
		}
	}
	return dist
}

// phase bundles what a phase needs to descend to its goal: the move set, the
// coordinate of a cube, the coordinate transition and the distance table.
type phase struct {
	moves []cube.Move
	coord func(*cube.Cube) int
	next  func(state, move int) int
	dist  []int8
}

// descend returns the moves of a shortest path from state to the goal,
// choosing at every step a move that decreases the distance by one.
func (p *phase) descend(state int, out []cube.Move) ([]cube.Move, bool) {
	d := p.dist[state]
	if d < 0 {
		return out, false
	}
	for ; d > 0; d-- {
		found := false
		for i := range p.moves {
			if n := p.next(state, i); p.dist[n] == d-1 {
				out = append(out, p.moves[i])
				state = n
				found = true
				break
			}
		}
		if !found {
			return out, false
		}
	}
	return out, true
}

func newPhase1() *phase {
	mt := buildMoveTable(nEO, phase1Moves, func(x int) cube.Cube { return eoCube(x) }, eoCoord)
	next := func(s, m int) int { return int(mt[s][m]) }
	return &phase{
		moves: phase1Moves,
		coord: eoCoord,
		next:  next,
		dist:  bfs(nEO, 0, len(phase1Moves), next),
	}
}

func newPhase2() *phase {
	co := buildMoveTable(nCO, phase2Moves, func(x int) cube.Cube { return coCube(x) }, coCoord)
	sl := buildMoveTable(nSlice, phase2Moves, func(x int) cube.Cube { return sliceCube(x) }, sliceCoord)
	next := func(s, m int) int {
		return int(co[s/nSlice][m])*nSlice + int(sl[s%nSlice][m])
	}
	solved := cube.Solved()
	coord := func(c *cube.Cube) int { return coCoord(c)*nSlice + sliceCoord(c) }
	goal := coord(&solved)
	return &phase{
		moves: phase2Moves,
		coord: coord,
		next:  next,
		dist:  bfs(nCO*nSlice, goal, len(phase2Moves), next),
	}
}

func newPhase3(g *cornerGroup) *phase {
	cosetRep := func(x int) cube.Cube {
		c := cube.Solved()
		c.CP = g.cosetRp[x]
		return c
	}
	cosetOf := func(c *cube.Cube) int { return int(g.coset[permRank(c.CP[:])]) }
	co := buildMoveTable(nCoset, phase3Moves, cosetRep, cosetOf)
	mt := buildMoveTable(nMComb, phase3Moves, mCube, mCoord)
	next := func(s, m int) int {
		return int(co[s/nMComb][m])*nMComb + int(mt[s%nMComb][m])
	}
	coord := func(c *cube.Cube) int { return cosetOf(c)*nMComb + mCoord(c) }
	solved := cube.Solved()
	return &phase{
		moves: phase3Moves,
		coord: coord,
		next:  next,
		dist:  bfs(nCoset*nMComb, coord(&solved), len(phase3Moves), next),
	}
}

func newPhase4(g *cornerGroup) *phase {
	n := len(phase4Moves)
	// Corner permutation within H.
	hm := make([][]int32, nHGroup)
	for h := range hm {
		hm[h] = make([]int32, n)
		for i, m := range phase4Moves {
			mc := cube.MoveCube(m)
			var q [8]uint8
			for k := range q {
				q[k] = g.elems[h][mc.CP[k]]
			}
			hm[h][i] = int32(g.hIndex[permRank(q[:])])
		}
	}
	// Permutation of each edge slice within its slots.
	slotSets := [3]*[4]uint8{&eSliceSlots, &mSliceSlots, &sSliceSlots}
	var sm [3][nPerm4][]int32
	for k, slots := range slotSets {
		for r := 0; r < nPerm4; r++ {
			var a [4]uint8
			permUnrank(r, 4, a[:])
			sm[k][r] = make([]int32, n)
			for i, m := range phase4Moves {
				mc := cube.MoveCube(m)
				var b [4]uint8
				for j, slot := range slots {
					src := mc.EP[slot]
					idx := -1
					for t, s := range slots {
						if s == src {
							idx = t
						}
					}
					if idx < 0 {
						panic("solver: half turn moved an edge between slices")
					}
					b[j] = a[idx]
				}
				sm[k][r][i] = int32(permRank(b[:]))
			}
		}
	}
	const per = nPerm4 * nPerm4 * nPerm4
	next := func(s, m int) int {
		h, rest := s/per, s%per
		e, mm, ss := rest/(nPerm4*nPerm4), rest/nPerm4%nPerm4, rest%nPerm4
		return int(hm[h][m])*per +
			int(sm[0][e][m])*nPerm4*nPerm4 + int(sm[1][mm][m])*nPerm4 + int(sm[2][ss][m])
	}
	coord := func(c *cube.Cube) int {
		h := int(g.hIndex[permRank(c.CP[:])])
		if h < 0 {
			return -1
		}
		return h*per + slicePerm(c, &eSliceSlots)*nPerm4*nPerm4 +
			slicePerm(c, &mSliceSlots)*nPerm4 + slicePerm(c, &sSliceSlots)
	}
	solved := cube.Solved()
	return &phase{
		moves: phase4Moves,
		coord: coord,
		next:  next,
		dist:  bfs(nHGroup*per, coord(&solved), n, next),
	}
}
