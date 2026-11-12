package sat

import "sort"

// Status is the outcome of [Solver.Solve].
type Status int

const (
	// Unsatisfiable means no assignment satisfies all clauses.
	Unsatisfiable Status = iota
	// Satisfiable means a model was found; see [Solver.Model].
	Satisfiable
)

func (s Status) String() string {
	if s == Satisfiable {
		return "SAT"
	}
	return "UNSAT"
}

// Stats are cumulative search statistics.
type Stats struct {
	Conflicts    uint64
	Decisions    uint64
	Propagations uint64
	Restarts     uint64
	Reductions   uint64
}

// Tuning constants (MiniSat defaults).
const (
	varDecay          = 0.95
	clauseDecay       = 0.999
	varRescaleLimit   = 1e100
	clauseRescaleLim  = 1e20
	restartBase       = 100
	minMaxLearnts     = 2000
	maxLearntsGrowth  = 1.1
	initialMaxLearnts = 1.0 / 3
)

type clause struct {
	lits     []Lit
	learnt   bool
	activity float64
}

type watcher struct {
	c       *clause
	blocker Lit
}

// Solver is a CDCL SAT solver. The zero value is not usable; create one with
// [NewSolver].
type Solver struct {
	ok      bool // false once the formula is known to be unsatisfiable
	clauses []*clause
	learnts []*clause

	watches [][]watcher // indexed by literal; visited when that literal becomes false

	assigns  []int8 // per variable
	level    []int32
	reason   []*clause
	trail    []Lit
	trailLim []int
	qhead    int

	activity []float64
	varInc   float64
	claInc   float64
	phase    []bool // last value of each variable; initially false
	order    varHeap

	seen  []uint8
	model []bool

	maxLearnts float64
	stats      Stats
}

// NewSolver returns an empty solver (a formula with no variables or clauses).
func NewSolver() *Solver {
	s := &Solver{ok: true, varInc: 1, claInc: 1}
	s.order.act = &s.activity
	return s
}

// NumVars returns the number of variables created so far.
func (s *Solver) NumVars() int { return len(s.assigns) }

// NumClauses returns the number of stored (non-unit, non-trivial) input clauses.
func (s *Solver) NumClauses() int { return len(s.clauses) }

// NumLearnts returns the number of learnt clauses currently stored.
func (s *Solver) NumLearnts() int { return len(s.learnts) }

// Stats returns the cumulative search statistics.
func (s *Solver) Stats() Stats { return s.stats }

// NewVar creates a fresh variable and returns it.
func (s *Solver) NewVar() Var {
	v := Var(len(s.assigns))
	s.assigns = append(s.assigns, lUndef)
	s.level = append(s.level, 0)
	s.reason = append(s.reason, nil)
	s.activity = append(s.activity, 0)
	s.phase = append(s.phase, false)
	s.seen = append(s.seen, 0)
	s.watches = append(s.watches, nil, nil)
	s.order.grow(len(s.assigns))
	s.order.insert(v)
	return v
}

func (s *Solver) value(l Lit) int8 {
	a := s.assigns[l>>1]
	if l&1 == 1 {
		return -a
	}
	return a
}

func (s *Solver) decisionLevel() int { return len(s.trailLim) }

// AddClause adds the clause (the disjunction of lits) to the formula and
// reports whether the formula may still be satisfiable; false means it is now
// known to be unsatisfiable. Variables not yet created are created
// automatically. Duplicate literals, tautologies, root-satisfied clauses and
// root-false literals are simplified away; unit clauses are propagated at the
// root level. The lits slice is not retained or modified.
func (s *Solver) AddClause(lits ...Lit) bool {
	for _, l := range lits {
		for int(l.Var()) >= s.NumVars() {
			s.NewVar()
		}
	}
	if !s.ok {
		return false
	}
	s.cancelUntil(0)

	ls := append([]Lit(nil), lits...)
	sort.Slice(ls, func(i, j int) bool { return ls[i] < ls[j] })
	out := ls[:0]
	prev := litUndef
	for _, l := range ls {
		switch {
		case s.value(l) == lTrue || l == prev.Not() && prev != litUndef:
			return true // satisfied at the root, or tautology
		case l == prev || s.value(l) == lFalse:
			// duplicate or root-false literal
		default:
			out = append(out, l)
			prev = l
		}
	}
	switch len(out) {
	case 0:
		s.ok = false
	case 1:
		s.enqueue(out[0], nil)
		s.ok = s.propagate() == nil
	default:
		c := &clause{lits: out}
		s.clauses = append(s.clauses, c)
		s.attach(c)
	}
	return s.ok
}

func (s *Solver) attach(c *clause) {
	s.watches[c.lits[0]] = append(s.watches[c.lits[0]], watcher{c, c.lits[1]})
	s.watches[c.lits[1]] = append(s.watches[c.lits[1]], watcher{c, c.lits[0]})
}

func (s *Solver) enqueue(l Lit, from *clause) {
	v := l.Var()
	if l.Negated() {
		s.assigns[v] = lFalse
	} else {
		s.assigns[v] = lTrue
	}
	s.level[v] = int32(s.decisionLevel())
	s.reason[v] = from
	s.trail = append(s.trail, l)
}

// cancelUntil undoes all assignments above the given decision level.
func (s *Solver) cancelUntil(lvl int) {
	if s.decisionLevel() <= lvl {
		return
	}
	for i := len(s.trail) - 1; i >= s.trailLim[lvl]; i-- {
		v := s.trail[i].Var()
		s.phase[v] = s.assigns[v] == lTrue
		s.assigns[v] = lUndef
		s.reason[v] = nil
		s.order.insert(v)
	}
	s.qhead = s.trailLim[lvl]
	s.trail = s.trail[:s.trailLim[lvl]]
	s.trailLim = s.trailLim[:lvl]
}

// Solve decides satisfiability of the clauses added so far. After a
// Satisfiable result, [Solver.Model] returns a satisfying assignment. More
// clauses may be added and Solve called again.
func (s *Solver) Solve() Status {
	s.model = nil
	if !s.ok {
		return Unsatisfiable
	}
	if s.maxLearnts == 0 {
		s.maxLearnts = float64(len(s.clauses)) * initialMaxLearnts
		if s.maxLearnts < minMaxLearnts {
			s.maxLearnts = minMaxLearnts
		}
	}
	for i := 0; ; i++ {
		budget := restartBase * luby(i)
		switch s.search(budget) {
		case lTrue:
			s.model = make([]bool, s.NumVars())
			for v := range s.model {
				s.model[v] = s.assigns[v] == lTrue
			}
			s.cancelUntil(0)
			return Satisfiable
		case lFalse:
			s.ok = false
			return Unsatisfiable
		}
		s.stats.Restarts++
		if float64(len(s.learnts)) >= s.maxLearnts {
			s.reduceDB()
			s.maxLearnts *= maxLearntsGrowth
		}
	}
}

// Model returns the satisfying assignment found by the last successful Solve,
// indexed by variable, or nil if the last call did not return Satisfiable.
func (s *Solver) Model() []bool { return append([]bool(nil), s.model...) }

// search runs CDCL until a model is found (lTrue), unsatisfiability is proved
// (lFalse) or the conflict budget is exhausted (lUndef, after restarting).
func (s *Solver) search(budget int) int8 {
	conflicts := 0
	for {
		if confl := s.propagate(); confl != nil {
			s.stats.Conflicts++
			conflicts++
			if s.decisionLevel() == 0 {
				return lFalse
			}
			learnt, bt := s.analyze(confl)
			s.cancelUntil(bt)
			if len(learnt) == 1 {
				s.enqueue(learnt[0], nil)
			} else {
				c := &clause{lits: learnt, learnt: true}
				s.learnts = append(s.learnts, c)
				s.attach(c)
				s.bumpClause(c)
				s.enqueue(learnt[0], c)
			}
			s.varInc /= varDecay
			s.claInc /= clauseDecay
			continue
		}
		if conflicts >= budget {
			s.cancelUntil(0)
			return lUndef
		}
		next := s.pickBranchLit()
		if next == litUndef {
			return lTrue
		}
		s.stats.Decisions++
		s.trailLim = append(s.trailLim, len(s.trail))
		s.enqueue(next, nil)
	}
}

// pickBranchLit returns the unassigned variable of highest activity with its
// saved phase, or litUndef when every variable is assigned.
func (s *Solver) pickBranchLit() Lit {
	for !s.order.empty() {
		v := s.order.removeMax()
		if s.assigns[v] == lUndef {
			return MkLit(v, !s.phase[v])
		}
	}
	return litUndef
}
