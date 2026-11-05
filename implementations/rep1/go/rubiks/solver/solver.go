package solver

import (
	"fmt"
	"sync"

	"rubiks/cube"
)

// MaxMoves is the longest solution Solve can return.
const MaxMoves = 7 + 10 + 13 + 15

// Solver solves cubes with Thistlethwaite's algorithm. The zero value is
// ready to use; the distance tables are built on first use. A Solver may be
// shared by multiple goroutines.
type Solver struct {
	once sync.Once
	t    *tables
}

// New returns a Solver. Equivalent to new(Solver), provided for clarity.
func New() *Solver { return new(Solver) }

var defaultSolver Solver

// Prepare builds the distance tables now instead of on first use. Calling it
// is optional.
func (s *Solver) Prepare() {
	s.once.Do(func() { s.t = newTables() })
}

// Solve returns a sequence of at most [MaxMoves] moves that takes c to the
// solved cube. It returns an error if c is not a reachable cube state.
// Consecutive turns of the same face across phase boundaries are merged.
func (s *Solver) Solve(c cube.Cube) ([]cube.Move, error) {
	if err := c.Verify(); err != nil {
		return nil, err
	}
	if c.IsSolved() {
		return nil, nil
	}
	s.Prepare()
	t := s.t
	var out []cube.Move

	// Each phase: compute the coordinate, descend, and apply the moves to the
	// cube so the next phase starts from the right state.
	type coords func(c *cube.Cube) (int, int)
	starts := [4]coords{
		func(c *cube.Cube) (int, int) { return coordFlip(c), 0 },
		func(c *cube.Cube) (int, int) { return coordTwist(c), t.coordSlice(c) },
		func(c *cube.Cube) (int, int) { return t.coordClass(c), t.coordMask8(c) },
		func(c *cube.Cube) (int, int) { return t.coordCorner96(c), coordEdgePerm(c) },
	}
	for i := range t.phases {
		a, b := starts[i](&c)
		start := len(out)
		var ok bool
		out, ok = t.phases[i].descend(a, b, out)
		if !ok {
			return nil, fmt.Errorf("solver: phase %d failed (internal error)", i+1)
		}
		c.ApplyAll(out[start:])
	}
	if !c.IsSolved() {
		return nil, fmt.Errorf("solver: cube not solved after four phases (internal error)")
	}
	return cube.Simplify(out), nil
}

// Solve solves c using a shared default Solver.
func Solve(c cube.Cube) ([]cube.Move, error) { return defaultSolver.Solve(c) }
