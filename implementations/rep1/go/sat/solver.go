package sat

import "sort"

// Status is the outcome of Solve.
type Status int

const (
	// Satisfiable means a model was found; see Solver.Model.
	Satisfiable Status = iota + 1
	// Unsatisfiable means the clauses added so far have no model.
	Unsatisfiable
)

func (s Status) String() string {
	switch s {
	case Satisfiable:
		return "SAT"
	case Unsatisfiable:
		return "UNSAT"
	}
	return "UNKNOWN"
}

// Stats holds counters describing the work done by a Solver.
type Stats struct {
	Conflicts    int
	Decisions    int
	Propagations int
	Restarts     int
	Learnts      int // learnt clauses currently stored
	Reductions   int
}

// Internal literal encoding: variable v (0-based) is 2v when true and 2v+1
// when false; negation is l^1.
type lit = int32

const noReason int32 = -1

// Truth values stored per literal.
const (
	valUndef int8 = 0
	valTrue  int8 = 1
	valFalse int8 = -1
)

type clause struct {
	lits  []lit
	act   float64
	learn bool
}

// Solver is a CDCL SAT solver. Create one with NewSolver, add clauses with
// AddClause, then call Solve. A Solver is not safe for concurrent use.
type Solver struct {
	nVars int
	ok    bool // false once the clause set is known to be unsatisfiable

	clauses []clause // storage; a clause reference is an index into it
	inputs  []int32  // references of stored input clauses, in storage order
	learnts []int32  // references of live learnt clauses
	watches [][]int32

	vals   []int8 // per literal
	level  []int32
	reason []int32
	phase  []bool // saved phase per variable (true = last value was true)
	trail  []lit
	lims   []int32 // trail length at the start of each decision level
	qhead  int

	activity []float64
	varInc   float64
	claInc   float64
	heap     *varHeap

	seen      []bool
	learntBuf []lit
	clearBuf  []lit
	addBuf    []lit

	maxLearnts int
	started    bool
	model      []bool
	stats      Stats
}

// NewSolver returns a solver over variables 1..numVars.
func NewSolver(numVars int) *Solver {
	if numVars < 0 {
		numVars = 0
	}
	s := &Solver{
		nVars:    numVars,
		ok:       true,
		watches:  make([][]int32, 2*numVars),
		vals:     make([]int8, 2*numVars),
		level:    make([]int32, numVars),
		reason:   make([]int32, numVars),
		phase:    make([]bool, numVars),
		activity: make([]float64, numVars),
		seen:     make([]bool, numVars),
		varInc:   1,
		claInc:   1,
	}
	s.heap = newVarHeap(&s.activity, numVars)
	for v := 0; v < numVars; v++ {
		s.reason[v] = noReason
		s.heap.insert(int32(v))
	}
	return s
}

// NumVars returns the number of variables of the solver.
func (s *Solver) NumVars() int { return s.nVars }

// Stats returns the solver's counters.
func (s *Solver) Stats() Stats {
	st := s.stats
	st.Learnts = len(s.learnts)
	return st
}

// Model returns the satisfying assignment found by the last call to Solve
// that returned Satisfiable: Model()[i] is the value of variable i+1. It
// returns nil if the last result was not Satisfiable.
func (s *Solver) Model() []bool { return s.model }

// AddClause adds the disjunction of the given DIMACS literals. It returns
// false if the solver is now known to be unsatisfiable (for example after an
// empty clause or a conflicting unit); once false, further clauses are
// ignored. Repeated literals are merged, tautologies are discarded, and
// literals already false at the root are removed. AddClause panics if a
// literal is 0 or refers to a variable outside 1..NumVars.
func (s *Solver) AddClause(dimacs ...int) bool {
	if !s.ok {
		return false
	}
	s.cancelUntil(0)
	c := s.addBuf[:0]
	for _, d := range dimacs {
		if d == 0 || abs(d) > s.nVars {
			panic("sat: literal out of range")
		}
		if d > 0 {
			c = append(c, lit(2*(d-1)))
		} else {
			c = append(c, lit(2*(-d-1)+1))
		}
	}
	sort.Slice(c, func(i, j int) bool { return c[i] < c[j] })
	out := c[:0]
	var prev lit = -1
	for _, l := range c {
		if l == prev {
			continue
		}
		if prev >= 0 && l == prev^1 && l&1 == 1 {
			s.addBuf = c
			return true // tautology
		}
		prev = l
		out = append(out, l)
	}
	c = out
	j := 0
	for _, l := range c {
		switch s.vals[l] {
		case valTrue:
			s.addBuf = c
			return true
		case valUndef:
			c[j] = l
			j++
		}
	}
	c = c[:j]
	s.addBuf = c
	switch len(c) {
	case 0:
		s.ok = false
	case 1:
		s.enqueue(c[0], noReason)
		if s.propagate() != noReason {
			s.ok = false
		}
	default:
		cr := s.newClause(append([]lit(nil), c...), false)
		s.inputs = append(s.inputs, cr)
		s.attach(cr)
	}
	return s.ok
}

func (s *Solver) newClause(lits []lit, learnt bool) int32 {
	s.clauses = append(s.clauses, clause{lits: lits, learn: learnt})
	return int32(len(s.clauses) - 1)
}

func (s *Solver) attach(cr int32) {
	c := s.clauses[cr].lits
	s.watches[c[0]] = append(s.watches[c[0]], cr)
	s.watches[c[1]] = append(s.watches[c[1]], cr)
}

func (s *Solver) decisionLevel() int { return len(s.lims) }

func (s *Solver) enqueue(l lit, from int32) {
	s.vals[l] = valTrue
	s.vals[l^1] = valFalse
	v := l >> 1
	s.level[v] = int32(len(s.lims))
	s.reason[v] = from
	s.trail = append(s.trail, l)
}

// cancelUntil undoes all assignments above decision level lvl.
func (s *Solver) cancelUntil(lvl int) {
	if len(s.lims) <= lvl {
		return
	}
	bound := int(s.lims[lvl])
	for i := len(s.trail) - 1; i >= bound; i-- {
		l := s.trail[i]
		v := l >> 1
		s.vals[l] = valUndef
		s.vals[l^1] = valUndef
		s.reason[v] = noReason
		s.phase[v] = l&1 == 0
		if !s.heap.contains(v) {
			s.heap.insert(v)
		}
	}
	s.trail = s.trail[:bound]
	s.lims = s.lims[:lvl]
	s.qhead = bound
}

// propagate performs unit propagation with two watched literals and returns
// the reference of a conflicting clause, or noReason if there is none.
func (s *Solver) propagate() int32 {
	for s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		s.stats.Propagations++
		fl := p ^ 1
		ws := s.watches[fl]
		i, j := 0, 0
	next:
		for i < len(ws) {
			cr := ws[i]
			i++
			c := s.clauses[cr].lits
			if c[0] == fl {
				c[0], c[1] = c[1], c[0]
			}
			if s.vals[c[0]] == valTrue {
				ws[j] = cr
				j++
				continue
			}
			for k := 2; k < len(c); k++ {
				if s.vals[c[k]] != valFalse {
					c[1], c[k] = c[k], fl
					s.watches[c[1]] = append(s.watches[c[1]], cr)
					continue next
				}
			}
			ws[j] = cr
			j++
			if s.vals[c[0]] == valFalse {
				for i < len(ws) {
					ws[j] = ws[i]
					i++
					j++
				}
				s.watches[fl] = ws[:j]
				s.qhead = len(s.trail)
				return cr
			}
			s.enqueue(c[0], cr)
		}
		s.watches[fl] = ws[:j]
	}
	return noReason
}

func (s *Solver) bumpVar(v int32) {
	s.activity[v] += s.varInc
	if s.activity[v] > 1e100 {
		for i := range s.activity {
			s.activity[i] *= 1e-100
		}
		s.varInc *= 1e-100
	}
	s.heap.increased(v)
}

func (s *Solver) bumpClause(cr int32) {
	c := &s.clauses[cr]
	c.act += s.claInc
	if c.act > 1e20 {
		for _, lr := range s.learnts {
			s.clauses[lr].act *= 1e-20
		}
		s.claInc *= 1e-20
	}
}

// analyze derives the first-UIP learnt clause from a conflict. The clause is
// left in s.learntBuf with the asserting literal first and, if it has more
// than one literal, a literal of the backjump level second. It returns the
// backjump level.
func (s *Solver) analyze(confl int32) int {
	learnt := append(s.learntBuf[:0], 0)
	pathC := 0
	var p lit = -1
	idx := len(s.trail) - 1
	cur := int32(len(s.lims))
	for {
		cl := &s.clauses[confl]
		if cl.learn {
			s.bumpClause(confl)
		}
		for _, q := range cl.lits {
			if q == p {
				continue
			}
			v := q >> 1
			if !s.seen[v] && s.level[v] > 0 {
				s.seen[v] = true
				s.bumpVar(v)
				if s.level[v] >= cur {
					pathC++
				} else {
					learnt = append(learnt, q)
				}
			}
		}
		for !s.seen[s.trail[idx]>>1] {
			idx--
		}
		p = s.trail[idx]
		idx--
		confl = s.reason[p>>1]
		s.seen[p>>1] = false
		pathC--
		if pathC <= 0 {
			break
		}
	}
	learnt[0] = p ^ 1

	// Local minimisation. seen keeps marking every literal of the original
	// clause, including those dropped, until the end.
	s.clearBuf = append(s.clearBuf[:0], learnt[1:]...)
	j := 1
	for i := 1; i < len(learnt); i++ {
		q := learnt[i]
		r := s.reason[q>>1]
		keep := r == noReason
		if !keep {
			for _, x := range s.clauses[r].lits {
				xv := x >> 1
				if xv == q>>1 {
					continue
				}
				if !s.seen[xv] && s.level[xv] > 0 {
					keep = true
					break
				}
			}
		}
		if keep {
			learnt[j] = q
			j++
		}
	}
	learnt = learnt[:j]
	for _, q := range s.clearBuf {
		s.seen[q>>1] = false
	}

	bt := 0
	if len(learnt) > 1 {
		m := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[learnt[i]>>1] > s.level[learnt[m]>>1] {
				m = i
			}
		}
		learnt[1], learnt[m] = learnt[m], learnt[1]
		bt = int(s.level[learnt[1]>>1])
	}
	s.learntBuf = learnt
	return bt
}

// search runs CDCL until the conflict budget is spent (returning 0), or the
// formula is decided (returning Satisfiable or Unsatisfiable).
func (s *Solver) search(budget int) Status {
	conflicts := 0
	for {
		confl := s.propagate()
		if confl != noReason {
			s.stats.Conflicts++
			conflicts++
			if s.decisionLevel() == 0 {
				return Unsatisfiable
			}
			bt := s.analyze(confl)
			s.cancelUntil(bt)
			learnt := s.learntBuf
			if len(learnt) == 1 {
				s.enqueue(learnt[0], noReason)
			} else {
				cr := s.newClause(append([]lit(nil), learnt...), true)
				s.clauses[cr].act = s.claInc
				s.learnts = append(s.learnts, cr)
				s.attach(cr)
				s.enqueue(learnt[0], cr)
			}
			s.varInc /= 0.95
			s.claInc /= 0.999
			continue
		}
		if conflicts >= budget {
			s.cancelUntil(0)
			return 0
		}
		// Decide.
		next := lit(-1)
		for len(s.heap.items) > 0 {
			v := s.heap.pop()
			if s.vals[2*v] == valUndef {
				if s.phase[v] {
					next = 2 * v
				} else {
					next = 2*v + 1
				}
				break
			}
		}
		if next < 0 {
			return Satisfiable
		}
		s.stats.Decisions++
		s.lims = append(s.lims, int32(len(s.trail)))
		s.enqueue(next, noReason)
	}
}

// reduceDB deletes the less active half of the learnt clauses (keeping
// binary clauses) and rebuilds all watch lists. It must be called at
// decision level 0.
func (s *Solver) reduceDB() {
	s.stats.Reductions++
	n := len(s.learnts)
	sort.SliceStable(s.learnts, func(i, j int) bool {
		return s.clauses[s.learnts[i]].act < s.clauses[s.learnts[j]].act
	})
	kept := s.learnts[:0]
	for i, cr := range s.learnts {
		if i < n/2 && len(s.clauses[cr].lits) > 2 {
			s.clauses[cr].lits = nil
			continue
		}
		kept = append(kept, cr)
	}
	s.learnts = kept
	for i := range s.watches {
		s.watches[i] = s.watches[i][:0]
	}
	for _, cr := range s.inputs {
		s.attach(cr)
	}
	for _, cr := range s.learnts {
		s.attach(cr)
	}
	s.maxLearnts = int(float64(s.maxLearnts) * 1.1)
}

// Solve decides satisfiability of the clauses added so far. It may be called
// again after adding more clauses.
func (s *Solver) Solve() Status {
	s.model = nil
	if !s.ok {
		return Unsatisfiable
	}
	s.cancelUntil(0)
	if !s.started {
		s.started = true
		s.maxLearnts = len(s.inputs) / 3
		if s.maxLearnts < 2000 {
			s.maxLearnts = 2000
		}
	}
	if s.propagate() != noReason {
		s.ok = false
		return Unsatisfiable
	}
	for i := 0; ; i++ {
		st := s.search(100 * luby(2, i))
		switch st {
		case Satisfiable:
			s.model = make([]bool, s.nVars)
			for v := range s.model {
				s.model[v] = s.vals[2*v] == valTrue
			}
			return st
		case Unsatisfiable:
			s.ok = false
			return st
		}
		s.stats.Restarts++
		if len(s.learnts) >= s.maxLearnts {
			s.reduceDB()
		}
	}
}
