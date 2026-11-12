package sat

import "sort"

// Result is the outcome of [Solver.Solve].
type Result int

const (
	// Unsatisfiable means no assignment satisfies all clauses.
	Unsatisfiable Result = iota
	// Satisfiable means a model was found; see [Solver.Model].
	Satisfiable
)

func (r Result) String() string {
	if r == Satisfiable {
		return "SAT"
	}
	return "UNSAT"
}

// Stats holds counters describing the work done by a solver.
type Stats struct {
	Conflicts    int64 // conflicts analysed
	Decisions    int64 // branching decisions
	Propagations int64 // literals propagated
	Restarts     int64 // restarts performed
	Reductions   int64 // learnt-clause database reductions
	Learnt       int   // learnt clauses currently stored
}

// Tunable constants of the algorithm.
const (
	varDecay        = 0.95
	clauseDecay     = 0.999
	varRescaleLimit = 1e100
	claRescaleLimit = 1e20
	restartBase     = 100
	lubyBase        = 2
	minMaxLearnts   = 2000
	maxLearntsGrow  = 1.1
)

type clause struct {
	lits    []lit
	act     float64
	learnt  bool
	deleted bool
}

type watcher struct {
	c       *clause
	blocker lit
}

// Solver is a CDCL SAT solver. The zero value is not usable; call [New].
type Solver struct {
	ok bool // false once the formula is known to be unsatisfiable

	clauses []*clause // stored (non-unit) input clauses
	learnts []*clause

	watches [][]watcher // indexed by literal: clauses to visit when it becomes true

	vals     []int8 // indexed by literal
	level    []int  // decision level per variable
	reason   []*clause
	trail    []lit
	trailLim []int
	qhead    int

	activity []float64
	varInc   float64
	claInc   float64
	order    varHeap
	phase    []bool // saved phase: true = last assigned negated

	seen      []bool
	toClear   []lit
	learntBuf []lit

	maxLearnts float64
	model      []bool
	stats      Stats
}

// New returns an empty solver.
func New() *Solver {
	s := &Solver{ok: true, varInc: 1, claInc: 1}
	s.order.act = &s.activity
	return s
}

// NumVars returns the number of variables known to the solver.
func (s *Solver) NumVars() int { return len(s.activity) }

// Stats returns the solver's counters.
func (s *Solver) Stats() Stats {
	st := s.stats
	st.Learnt = len(s.learnts)
	return st
}

// Reserve makes sure variables 1..n exist, even if no clause mentions them.
func (s *Solver) Reserve(n int) {
	for s.NumVars() < n {
		v := s.NumVars()
		s.vals = append(s.vals, valUndef, valUndef)
		s.watches = append(s.watches, nil, nil)
		s.level = append(s.level, 0)
		s.reason = append(s.reason, nil)
		s.activity = append(s.activity, 0)
		s.phase = append(s.phase, true) // initial phase: false
		s.seen = append(s.seen, false)
		s.order.grow(v + 1)
		s.order.insert(v)
	}
}

func (s *Solver) decisionLevel() int { return len(s.trailLim) }

// AddClause adds the clause made of the given DIMACS literals (non-zero
// integers; variable k is k, its negation -k), growing the variable set as
// needed. Duplicate literals are merged, tautologies and clauses satisfied at
// the root are dropped, and root-false literals are removed; a resulting unit
// is assigned and propagated. It returns false if the solver is now known to
// be unsatisfiable. It must not be called during a search.
func (s *Solver) AddClause(lits ...int) bool {
	if !s.ok {
		return false
	}
	ls := make([]lit, 0, len(lits))
	for _, x := range lits {
		if x == 0 {
			panic("sat: literal 0 in clause")
		}
		v := x
		if v < 0 {
			v = -v
		}
		s.Reserve(v)
		ls = append(ls, fromDimacs(x))
	}
	sort.Slice(ls, func(i, j int) bool { return ls[i] < ls[j] })
	out := ls[:0]
	prev := litUndef
	for _, l := range ls {
		switch {
		case s.vals[l] == valTrue || l == prev.neg() && prev != litUndef:
			return true // satisfied at root, or tautology
		case l == prev || s.vals[l] == valFalse:
			// duplicate or root-false literal: drop
		default:
			out = append(out, l)
			prev = l
		}
	}
	switch len(out) {
	case 0:
		s.ok = false
		return false
	case 1:
		s.enqueue(out[0], nil)
		if s.propagate() != nil {
			s.ok = false
		}
		return s.ok
	}
	c := &clause{lits: out}
	s.clauses = append(s.clauses, c)
	s.attach(c)
	return true
}

func (s *Solver) attach(c *clause) {
	s.watches[c.lits[0].neg()] = append(s.watches[c.lits[0].neg()], watcher{c, c.lits[1]})
	s.watches[c.lits[1].neg()] = append(s.watches[c.lits[1].neg()], watcher{c, c.lits[0]})
}

func (s *Solver) enqueue(l lit, from *clause) {
	v := l.variable()
	s.vals[l] = valTrue
	s.vals[l.neg()] = valFalse
	s.level[v] = s.decisionLevel()
	if s.decisionLevel() == 0 {
		from = nil // root facts never need an explanation
	}
	s.reason[v] = from
	s.trail = append(s.trail, l)
}

// Solve decides satisfiability of the clauses added so far.
func (s *Solver) Solve() Result {
	if !s.ok {
		return Unsatisfiable
	}
	if s.propagate() != nil {
		s.ok = false
		return Unsatisfiable
	}
	if s.maxLearnts == 0 {
		s.maxLearnts = float64(len(s.clauses) / 3)
		if s.maxLearnts < minMaxLearnts {
			s.maxLearnts = minMaxLearnts
		}
	}
	for i := 0; ; i++ {
		budget := int64(restartBase * luby(lubyBase, i))
		switch s.search(budget) {
		case searchSat:
			return Satisfiable
		case searchUnsat:
			s.ok = false
			return Unsatisfiable
		}
		s.stats.Restarts++
		if float64(len(s.learnts)) >= s.maxLearnts {
			s.reduceDB()
			s.maxLearnts *= maxLearntsGrow
		}
	}
}

// Model returns the satisfying assignment found by the last successful
// Solve: element i-1 is the value of variable i. It returns nil if the last
// Solve did not find a model.
func (s *Solver) Model() []bool { return s.model }

type searchResult int

const (
	searchRestart searchResult = iota
	searchSat
	searchUnsat
)

func (s *Solver) search(budget int64) searchResult {
	var conflicts int64
	for {
		confl := s.propagate()
		if confl != nil {
			conflicts++
			s.stats.Conflicts++
			if s.decisionLevel() == 0 {
				return searchUnsat
			}
			learnt, bt := s.analyze(confl)
			s.cancelUntil(bt)
			if len(learnt) == 1 {
				s.enqueue(learnt[0], nil)
			} else {
				c := &clause{lits: append([]lit(nil), learnt...), learnt: true}
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
			return searchRestart
		}
		next := s.pickBranch()
		if next == litUndef {
			s.saveModel()
			s.cancelUntil(0)
			return searchSat
		}
		s.stats.Decisions++
		s.trailLim = append(s.trailLim, len(s.trail))
		s.enqueue(next, nil)
	}
}

func (s *Solver) saveModel() {
	s.model = make([]bool, s.NumVars())
	for v := range s.model {
		s.model[v] = s.vals[mkLit(v, false)] == valTrue
	}
}

// pickBranch returns the decision literal: the unassigned variable of highest
// activity, with its saved phase. It returns litUndef if all are assigned.
func (s *Solver) pickBranch() lit {
	for !s.order.empty() {
		v := s.order.removeMax()
		if s.vals[mkLit(v, false)] == valUndef {
			return mkLit(v, s.phase[v])
		}
	}
	return litUndef
}

// cancelUntil undoes all assignments above decision level lvl.
func (s *Solver) cancelUntil(lvl int) {
	if s.decisionLevel() <= lvl {
		return
	}
	for i := len(s.trail) - 1; i >= s.trailLim[lvl]; i-- {
		l := s.trail[i]
		v := l.variable()
		s.vals[l] = valUndef
		s.vals[l.neg()] = valUndef
		s.reason[v] = nil
		s.phase[v] = l.negated()
		if !s.order.contains(v) {
			s.order.insert(v)
		}
	}
	s.qhead = s.trailLim[lvl]
	s.trail = s.trail[:s.trailLim[lvl]]
	s.trailLim = s.trailLim[:lvl]
}
