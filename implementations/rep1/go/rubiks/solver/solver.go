package solver

import (
	"errors"
	"fmt"

	"example.com/rubiks/cube"
)

// MaxSolutionLength is the longest solution Solve can return: the phases of
// Thistlethwaite's algorithm need at most 7, 10, 13 and 15 moves.
const MaxSolutionLength = 7 + 10 + 13 + 15

// Solver holds the distance tables of the four phases. Building one takes a
// fraction of a second; a Solver is immutable afterwards and safe for
// concurrent use.
type Solver struct {
	phases [4]*phase
}

// New builds the distance tables and returns a ready Solver.
func New() *Solver {
	g := newCornerGroup()
	return &Solver{phases: [4]*phase{newPhase1(), newPhase2(), newPhase3(g), newPhase4(g)}}
}

// Solve returns a sequence of moves that takes c to the solved cube. The
// sequence has at most [MaxSolutionLength] moves and is the concatenation of
// four optimal phase solutions. It returns an error if c is not a valid,
// solvable cube state.
func (s *Solver) Solve(c cube.Cube) ([]cube.Move, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	sol := make([]cube.Move, 0, MaxSolutionLength)
	for i, p := range s.phases {
		start := len(sol)
		var ok bool
		sol, ok = p.descend(p.coord(&c), sol)
		if !ok {
			return nil, fmt.Errorf("solver: phase %d failed to reach its goal", i+1)
		}
		c.ApplyAll(sol[start:])
	}
	if !c.IsSolved() {
		return nil, errors.New("solver: internal error: cube not solved")
	}
	return sol, nil
}

// PhaseDepths returns, for each of the four phases, the largest distance in
// that phase's table, i.e. the most moves the phase can ever need.
func (s *Solver) PhaseDepths() [4]int {
	var out [4]int
	for i, p := range s.phases {
		for _, d := range p.dist {
			if int(d) > out[i] {
				out[i] = int(d)
			}
		}
	}
	return out
}
