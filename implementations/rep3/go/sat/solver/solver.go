// Package solver implements a conflict-driven clause-learning (CDCL) SAT
// solver.
//
// The solver uses two watched literals per clause, first-UIP clause learning
// with local clause minimisation, VSIDS branching driven by an indexed heap,
// phase saving, Luby restarts and periodic deletion of low-activity learnt
// clauses. The search is fully deterministic: the same clauses added in the
// same order always produce the same model.
//
// Basic use:
//
//	s := solver.New(3)
//	s.AddClause(1, -2)
//	s.AddClause(2, 3)
//	if s.Solve() == solver.Sat {
//		fmt.Println(s.Model()) // one bool per variable
//	}
//
// Literals are DIMACS-style non-zero integers: k is variable k true and -k is
// variable k false, with variables numbered from 1.
package solver

import (
	"sort"
)

// Result is the outcome of Solve.
type Result int

const (
	// Unsat means the formula has no satisfying assignment.
	Unsat Result = iota
	// Sat means a satisfying assignment was found; see Solver.Model.
	Sat
)

func (r Result) String() string {
	if r == Sat {
		return "SAT"
	}
	return "UNSAT"
}

// Stats reports counters collected during search.
type Stats struct {
	Conflicts    int64
	Decisions    int64
	Propagations int64
	Restarts     int64
	Learnts      int // learnt clauses currently stored
	Reductions   int64
}

// lit encodes a literal: variable v (0-based) is 2v when true and 2v+1 when
// false. Negation is lit^1.
type lit int32

// Truth values per literal.
const (
	lUndef int8 = 0
	lTrue  int8 = 1
	lFalse int8 = -1
)

type clause struct {
	lits   []lit
	act    float64
	learnt bool
}

// Solver is a CDCL SAT solver. The zero value is not usable; call New.
type Solver struct {
	ok bool // false once the formula is known to be unsatisfiable

	nvars   int
	clauses []*clause // stored input clauses, in insertion order
	learnts []*clause // stored learnt clauses
	watches [][]*clause

	val    []int8 // per literal
	level  []int32
	reason []*clause
	phase  []bool // saved phase per variable (true = positive)
	trail  []lit
	lims   []int // trail length at the start of each decision level
	qhead  int

	activity []float64
	varInc   float64
	claInc   float64
	order    varHeap

	seen    []bool
	learntB []lit // scratch learnt-clause buffer
	toClear []lit
	addBuf  []lit

	maxLearnts int
	model      []bool
	stats      Stats
}

// New returns a solver with n variables (numbered 1..n). More variables are
// created automatically when AddClause mentions them, or explicitly with
// NewVar.
func New(n int) *Solver {
	s := &Solver{ok: true, varInc: 1, claInc: 1}
	s.order.act = &s.activity
	s.ensureVars(n)
	return s
}

// NumVars returns the number of variables.
func (s *Solver) NumVars() int { return s.nvars }

// NewVar adds a fresh variable and returns its (1-based) number.
func (s *Solver) NewVar() int {
	s.ensureVars(s.nvars + 1)
	return s.nvars
}

func (s *Solver) ensureVars(n int) {
	for s.nvars < n {
		v := int32(s.nvars)
		s.nvars++
		s.val = append(s.val, lUndef, lUndef)
		s.watches = append(s.watches, nil, nil)
		s.level = append(s.level, 0)
		s.reason = append(s.reason, nil)
		s.phase = append(s.phase, false)
		s.activity = append(s.activity, 0)
		s.seen = append(s.seen, false)
		s.order.grow(s.nvars)
		s.order.insert(v)
	}
}

// Stats returns the search counters.
func (s *Solver) Stats() Stats {
	st := s.stats
	st.Learnts = len(s.learnts)
	return st
}

func (s *Solver) decisionLevel() int { return len(s.lims) }

func varOf(l lit) int32 { return int32(l) >> 1 }

func (s *Solver) enqueue(l lit, from *clause) {
	s.val[l] = lTrue
	s.val[l^1] = lFalse
	v := varOf(l)
	s.level[v] = int32(len(s.lims))
	s.reason[v] = from
	s.trail = append(s.trail, l)
}

func toLit(x int) lit {
	if x > 0 {
		return lit(2 * (x - 1))
	}
	return lit(2*(-x-1) + 1)
}

// AddClause adds the clause (l1 ∨ l2 ∨ ...) given as DIMACS literals. It
// must be called before Solve. Duplicate literals are merged and tautologies
// are ignored. It returns false if the formula is now known to be
// unsatisfiable (an empty clause or a conflicting unit); once it has returned
// false further clauses are ignored and Solve returns Unsat.
//
// A zero literal panics.
func (s *Solver) AddClause(lits ...int) bool {
	if !s.ok {
		return false
	}
	buf := s.addBuf[:0]
	for _, x := range lits {
		if x == 0 {
			panic("solver: zero literal in clause")
		}
		v := x
		if v < 0 {
			v = -v
		}
		s.ensureVars(v)
		buf = append(buf, toLit(x))
	}
	s.addBuf = buf
	sort.Slice(buf, func(i, j int) bool { return buf[i] < buf[j] })

	// Dedupe, detect tautologies, simplify against the root assignment.
	j := 0
	prev := lit(-1)
	for _, l := range buf {
		if l == prev {
			continue
		}
		if prev >= 0 && l == prev^1 {
			return true // tautology (p and ¬p are adjacent once sorted)
		}
		prev = l
		switch s.val[l] {
		case lTrue:
			return true
		case lFalse:
			continue
		}
		buf[j] = l
		j++
	}
	buf = buf[:j]
	if j == 0 {
		s.ok = false
		return false
	}
	if j == 1 {
		s.enqueue(buf[0], nil)
		if s.propagate() != nil {
			s.ok = false
		}
		return s.ok
	}
	c := &clause{lits: append([]lit(nil), buf...)}
	s.clauses = append(s.clauses, c)
	s.attach(c)
	return true
}

func (s *Solver) attach(c *clause) {
	s.watches[c.lits[0]] = append(s.watches[c.lits[0]], c)
	s.watches[c.lits[1]] = append(s.watches[c.lits[1]], c)
}

// Solve decides satisfiability of the clauses added so far. On Sat the
// assignment is available through Model and Value.
func (s *Solver) Solve() Result {
	if !s.ok {
		return Unsat
	}
	s.maxLearnts = len(s.clauses) / 3
	if s.maxLearnts < 2000 {
		s.maxLearnts = 2000
	}
	for i := 0; ; i++ {
		switch s.search(100 * luby(i)) {
		case searchSat:
			s.model = make([]bool, s.nvars)
			for v := range s.model {
				s.model[v] = s.val[2*v] == lTrue
			}
			s.cancelUntil(0)
			return Sat
		case searchUnsat:
			s.ok = false
			return Unsat
		}
		s.stats.Restarts++
		if len(s.learnts) >= s.maxLearnts {
			s.reduceDB()
			s.maxLearnts = int(float64(s.maxLearnts) * 1.1)
		}
	}
}

// Model returns the satisfying assignment found by the last Solve that
// returned Sat; element i is the value of variable i+1. It returns nil if
// there is no model.
func (s *Solver) Model() []bool { return s.model }

// Value reports the value of variable v (1-based) in the last model.
func (s *Solver) Value(v int) bool { return s.model[v-1] }

type searchStatus int

const (
	searchRestart searchStatus = iota
	searchSat
	searchUnsat
)

// luby returns the i-th (0-based) element of the Luby sequence with base 2:
// 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...
func luby(x int) int {
	size, seq := 1, 0
	for size < x+1 {
		seq++
		size = 2*size + 1
	}
	for size-1 != x {
		size = (size - 1) >> 1
		seq--
		x %= size
	}
	return 1 << uint(seq)
}

func (s *Solver) search(budget int) searchStatus {
	conflicts := 0
	for {
		confl := s.propagate()
		if confl != nil {
			s.stats.Conflicts++
			conflicts++
			if s.decisionLevel() == 0 {
				return searchUnsat
			}
			bt := s.analyze(confl)
			s.learn(bt)
			s.varInc /= 0.95
			s.claInc /= 0.999
			continue
		}
		if conflicts >= budget {
			s.cancelUntil(0)
			return searchRestart
		}
		v := s.pickBranch()
		if v < 0 {
			return searchSat
		}
		s.stats.Decisions++
		s.lims = append(s.lims, len(s.trail))
		l := lit(2 * v)
		if !s.phase[v] {
			l |= 1
		}
		s.enqueue(l, nil)
	}
}

func (s *Solver) pickBranch() int32 {
	for !s.order.empty() {
		v := s.order.pop()
		if s.val[2*v] == lUndef {
			return v
		}
	}
	return -1
}

// learn backtracks to level bt and stores the clause in s.learntB.
func (s *Solver) learn(bt int) {
	s.cancelUntil(bt)
	if len(s.learntB) == 1 {
		s.enqueue(s.learntB[0], nil)
		return
	}
	c := &clause{lits: append([]lit(nil), s.learntB...), act: s.claInc, learnt: true}
	s.learnts = append(s.learnts, c)
	s.attach(c)
	s.enqueue(c.lits[0], c)
}

// cancelUntil undoes assignments down to decision level lvl.
func (s *Solver) cancelUntil(lvl int) {
	if len(s.lims) <= lvl {
		return
	}
	base := s.lims[lvl]
	for i := len(s.trail) - 1; i >= base; i-- {
		l := s.trail[i]
		v := varOf(l)
		s.val[l] = lUndef
		s.val[l^1] = lUndef
		s.reason[v] = nil
		s.phase[v] = l&1 == 0
		s.order.insert(v)
	}
	s.trail = s.trail[:base]
	s.lims = s.lims[:lvl]
	s.qhead = len(s.trail)
}
