package solver

import "sort"

// Result is the outcome of Solve.
type Result int

const (
	// Unsat means the clauses added so far are unsatisfiable.
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

// Internal literal encoding: variable v (0-based) is literal 2v when true and
// 2v+1 when false; negation is lit^1.
type lit = int32

// Truth values of a literal.
const (
	lUndef int8 = 0
	lTrue  int8 = 1
	lFalse int8 = 2
)

const noReason int32 = -1

type clause struct {
	lits   []lit
	act    float64
	learnt bool
}

// Solver is a CDCL SAT solver. The zero value is not usable; call New.
type Solver struct {
	ok bool // false once the clause set is known to be unsatisfiable

	db      []clause // clause storage; references are indices into db
	clauses []int32  // live input clauses (stored form), in storage order
	learnts []int32  // live learnt clauses
	watches [][]int32

	val      []int8 // per literal
	level    []int32
	reason   []int32
	phase    []bool // saved phase per variable (true = positive)
	seen     []bool
	activity []float64
	order    varHeap

	trail    []lit
	trailLim []int
	qhead    int

	varInc, claInc float64
	maxLearnts     int
	minLearnts     int // floor for the initial learnt-clause limit

	learntBuf []lit
	toClear   []lit
	tmp       []lit

	conflicts int
	model     []bool
}

// New returns a solver over variables 1..numVars. More variables are created
// on demand by AddClause.
func New(numVars int) *Solver {
	s := &Solver{ok: true, varInc: 1, claInc: 1, minLearnts: 2000}
	s.order.act = &s.activity
	s.grow(numVars)
	return s
}

// NumVars returns the number of variables.
func (s *Solver) NumVars() int { return len(s.activity) }

// Conflicts returns the number of conflicts encountered so far.
func (s *Solver) Conflicts() int { return s.conflicts }

// grow makes variables 0..n-1 exist, inserting new ones in the decision heap
// in increasing order.
func (s *Solver) grow(n int) {
	old := len(s.activity)
	if n <= old {
		return
	}
	for v := old; v < n; v++ {
		s.val = append(s.val, lUndef, lUndef)
		s.watches = append(s.watches, nil, nil)
		s.level = append(s.level, 0)
		s.reason = append(s.reason, noReason)
		s.phase = append(s.phase, false)
		s.seen = append(s.seen, false)
		s.activity = append(s.activity, 0)
	}
	s.order.grow(n)
	for v := old; v < n; v++ {
		s.order.insert(int32(v))
	}
}

func (s *Solver) decisionLevel() int { return len(s.trailLim) }

func (s *Solver) enqueue(p lit, from int32) {
	s.val[p] = lTrue
	s.val[p^1] = lFalse
	v := p >> 1
	s.level[v] = int32(len(s.trailLim))
	s.reason[v] = from
	s.trail = append(s.trail, p)
}

// AddClause adds a clause of DIMACS literals (a clause with no literals is
// the empty clause). It returns false if the formula is now known to be
// unsatisfiable. Duplicate literals are removed and tautologies are
// discarded. Clauses may be added between calls to Solve.
func (s *Solver) AddClause(dimacs ...int) bool {
	if !s.ok {
		return false
	}
	s.cancelUntil(0)
	buf := s.tmp[:0]
	for _, x := range dimacs {
		if x == 0 {
			panic("solver: zero is not a literal")
		}
		v := x
		if v < 0 {
			v = -v
		}
		s.grow(v)
		l := lit(2 * (v - 1))
		if x < 0 {
			l |= 1
		}
		buf = append(buf, l)
	}
	sort.Slice(buf, func(i, j int) bool { return buf[i] < buf[j] })
	// Dedupe, detect tautologies, drop root-false literals.
	out := buf[:0]
	prev := lit(-1)
	for _, l := range buf {
		if l == prev {
			continue
		}
		if prev >= 0 && l == prev^1 && prev&1 == 0 {
			s.tmp = buf
			return true // p and ¬p
		}
		prev = l
		switch s.val[l] {
		case lTrue:
			s.tmp = buf
			return true
		case lFalse:
			continue
		}
		out = append(out, l)
	}
	s.tmp = buf
	switch len(out) {
	case 0:
		s.ok = false
		return false
	case 1:
		s.enqueue(out[0], noReason)
		if s.propagate() != noReason {
			s.ok = false
		}
		return s.ok
	}
	cr := s.newClause(append([]lit(nil), out...), false)
	s.clauses = append(s.clauses, cr)
	s.attach(cr)
	return true
}

func (s *Solver) newClause(lits []lit, learnt bool) int32 {
	s.db = append(s.db, clause{lits: lits, learnt: learnt})
	return int32(len(s.db) - 1)
}

func (s *Solver) attach(cr int32) {
	c := s.db[cr].lits
	s.watches[c[0]] = append(s.watches[c[0]], cr)
	s.watches[c[1]] = append(s.watches[c[1]], cr)
}

// propagate performs unit propagation and returns a conflicting clause
// reference, or noReason if there is none.
func (s *Solver) propagate() int32 {
	for s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		fl := p ^ 1
		ws := s.watches[fl]
		i, j := 0, 0
		for i < len(ws) {
			cr := ws[i]
			i++
			c := s.db[cr].lits
			if c[0] == fl {
				c[0], c[1] = c[1], c[0]
			}
			if s.val[c[0]] == lTrue {
				ws[j] = cr
				j++
				continue
			}
			moved := false
			for k := 2; k < len(c); k++ {
				if s.val[c[k]] != lFalse {
					c[1], c[k] = c[k], fl
					s.watches[c[1]] = append(s.watches[c[1]], cr)
					moved = true
					break
				}
			}
			if moved {
				continue
			}
			ws[j] = cr
			j++
			if s.val[c[0]] == lFalse {
				for i < len(ws) {
					ws[j] = ws[i]
					j++
					i++
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

func (s *Solver) cancelUntil(lvl int) {
	if s.decisionLevel() <= lvl {
		return
	}
	for i := len(s.trail) - 1; i >= s.trailLim[lvl]; i-- {
		p := s.trail[i]
		v := p >> 1
		s.val[p] = lUndef
		s.val[p^1] = lUndef
		s.reason[v] = noReason
		s.phase[v] = p&1 == 0
		s.order.insert(v)
	}
	s.trail = s.trail[:s.trailLim[lvl]]
	s.trailLim = s.trailLim[:lvl]
	s.qhead = len(s.trail)
}

func (s *Solver) bumpVar(v int32) {
	s.activity[v] += s.varInc
	if s.activity[v] > 1e100 {
		for i := range s.activity {
			s.activity[i] *= 1e-100
		}
		s.varInc *= 1e-100
	}
	s.order.increased(v)
}

func (s *Solver) bumpClause(c *clause) {
	c.act += s.claInc
	if c.act > 1e20 {
		for _, cr := range s.learnts {
			s.db[cr].act *= 1e-20
		}
		s.claInc *= 1e-20
	}
}

// analyze performs first-UIP conflict analysis with local minimisation. It
// leaves the learnt clause in s.learntBuf (asserting literal first, a literal
// of the backjump level second) and returns the backjump level.
func (s *Solver) analyze(confl int32) int {
	learnt := append(s.learntBuf[:0], 0)
	counter := 0
	p := lit(-1)
	idx := len(s.trail) - 1
	cur := int32(s.decisionLevel())
	for {
		c := &s.db[confl]
		if c.learnt {
			s.bumpClause(c)
		}
		for _, q := range c.lits {
			if q == p {
				continue
			}
			v := q >> 1
			if !s.seen[v] && s.level[v] > 0 {
				s.seen[v] = true
				s.bumpVar(v)
				if s.level[v] >= cur {
					counter++
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
		counter--
		if counter <= 0 {
			break
		}
	}
	learnt[0] = p ^ 1

	// Local minimisation; seen keeps marking every literal of the
	// unminimised clause until it is cleared below.
	s.toClear = append(s.toClear[:0], learnt[1:]...)
	j := 1
	for i := 1; i < len(learnt); i++ {
		q := learnt[i]
		r := s.reason[q>>1]
		keep := r == noReason
		if !keep {
			for _, x := range s.db[r].lits {
				if x>>1 == q>>1 {
					continue
				}
				if !s.seen[x>>1] && s.level[x>>1] > 0 {
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
	for _, q := range s.toClear {
		s.seen[q>>1] = false
	}

	bt := 0
	if len(learnt) > 1 {
		mi := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[learnt[i]>>1] > s.level[learnt[mi]>>1] {
				mi = i
			}
		}
		learnt[1], learnt[mi] = learnt[mi], learnt[1]
		bt = int(s.level[learnt[1]>>1])
	}
	s.learntBuf = learnt
	return bt
}

// reduceDB deletes the less active half of the learnt clauses (keeping binary
// clauses) and rebuilds all watch lists. It must be called at level 0.
func (s *Solver) reduceDB() {
	n := len(s.learnts)
	sort.SliceStable(s.learnts, func(i, j int) bool {
		return s.db[s.learnts[i]].act < s.db[s.learnts[j]].act
	})
	kept := s.learnts[:0]
	for i, cr := range s.learnts {
		if i < n/2 && len(s.db[cr].lits) > 2 {
			s.db[cr].lits = nil
			continue
		}
		kept = append(kept, cr)
	}
	s.learnts = kept
	for i := range s.watches {
		s.watches[i] = s.watches[i][:0]
	}
	for _, cr := range s.clauses {
		s.attach(cr)
	}
	for _, cr := range s.learnts {
		s.attach(cr)
	}
	s.maxLearnts = int(float64(s.maxLearnts) * 1.1)
}

// decide opens a new decision level on the most active unassigned variable.
// It returns false when every variable is assigned.
func (s *Solver) decide() bool {
	for !s.order.empty() {
		v := s.order.pop()
		if s.val[2*v] == lUndef {
			s.trailLim = append(s.trailLim, len(s.trail))
			p := lit(2 * v)
			if !s.phase[v] {
				p |= 1
			}
			s.enqueue(p, noReason)
			return true
		}
	}
	return false
}

type searchResult int

const (
	searchUnsat searchResult = iota
	searchSat
	searchRestart
)

func (s *Solver) search(budget int) searchResult {
	used := 0
	for {
		confl := s.propagate()
		if confl != noReason {
			s.conflicts++
			used++
			if s.decisionLevel() == 0 {
				return searchUnsat
			}
			bt := s.analyze(confl)
			s.cancelUntil(bt)
			learnt := s.learntBuf
			if len(learnt) == 1 {
				s.enqueue(learnt[0], noReason)
			} else {
				cr := s.newClause(append([]lit(nil), learnt...), true)
				s.db[cr].act = s.claInc
				s.learnts = append(s.learnts, cr)
				s.attach(cr)
				s.enqueue(learnt[0], cr)
			}
			s.varInc /= 0.95
			s.claInc /= 0.999
			continue
		}
		if used >= budget {
			s.cancelUntil(0)
			return searchRestart
		}
		if !s.decide() {
			return searchSat
		}
	}
}

// Solve decides satisfiability of the clauses added so far. After Sat, Model
// and Value report the satisfying assignment. Clauses may be added and Solve
// called again.
func (s *Solver) Solve() Result {
	if !s.ok {
		return Unsat
	}
	s.cancelUntil(0)
	s.maxLearnts = len(s.clauses) / 3
	if s.maxLearnts < s.minLearnts {
		s.maxLearnts = s.minLearnts
	}
	for i := 0; ; i++ {
		switch s.search(100 * luby(i)) {
		case searchUnsat:
			s.ok = false
			return Unsat
		case searchSat:
			s.model = s.model[:0]
			for v := 0; v < s.NumVars(); v++ {
				s.model = append(s.model, s.val[2*v] == lTrue)
			}
			s.cancelUntil(0)
			return Sat
		}
		if len(s.learnts) >= s.maxLearnts {
			s.reduceDB()
		}
	}
}

// Model returns a copy of the satisfying assignment found by the last Solve
// that returned Sat; element i is the value of variable i+1.
func (s *Solver) Model() []bool { return append([]bool(nil), s.model...) }

// Value reports the value of DIMACS variable v (1-based) in the last model.
func (s *Solver) Value(v int) bool { return s.model[v-1] }
