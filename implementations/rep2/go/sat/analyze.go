package sat

// analyze derives the first-UIP learnt clause from a conflict at a non-zero
// decision level. It returns the clause, with the asserting literal first and
// (for clauses longer than one) a literal of the backjump level second, and
// the level to backjump to. It bumps the activity of every variable and
// learnt clause involved.
func (s *Solver) analyze(confl *clause) (learnt []Lit, backtrack int) {
	learnt = append(learnt, litUndef) // slot for the asserting literal
	pathC := 0
	p := litUndef
	idx := len(s.trail) - 1
	dl := int32(s.decisionLevel())

	for {
		if confl.learnt {
			s.bumpClause(confl)
		}
		start := 0
		if p != litUndef {
			start = 1 // skip the literal this clause implied
		}
		for _, q := range confl.lits[start:] {
			v := q.Var()
			if s.seen[v] == 0 && s.level[v] > 0 {
				s.bumpVar(v)
				s.seen[v] = 1
				if s.level[v] >= dl {
					pathC++
				} else {
					learnt = append(learnt, q)
				}
			}
		}
		for s.seen[s.trail[idx].Var()] == 0 {
			idx--
		}
		p = s.trail[idx]
		idx--
		confl = s.reason[p.Var()]
		s.seen[p.Var()] = 0
		pathC--
		if pathC <= 0 {
			break
		}
	}
	learnt[0] = p.Not()

	// Local minimisation: drop a literal whose reason clause is entirely made
	// of literals already in the learnt clause (or fixed at the root).
	toClear := append([]Lit(nil), learnt...)
	j := 1
	for i := 1; i < len(learnt); i++ {
		if !s.redundant(learnt[i]) {
			learnt[j] = learnt[i]
			j++
		}
	}
	learnt = learnt[:j]
	for _, l := range toClear {
		s.seen[l.Var()] = 0
	}

	if len(learnt) > 1 {
		maxI := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[learnt[i].Var()] > s.level[learnt[maxI].Var()] {
				maxI = i
			}
		}
		learnt[1], learnt[maxI] = learnt[maxI], learnt[1]
		backtrack = int(s.level[learnt[1].Var()])
	}
	return learnt, backtrack
}

// redundant reports whether l is implied by the other seen literals through
// its reason clause alone.
func (s *Solver) redundant(l Lit) bool {
	c := s.reason[l.Var()]
	if c == nil {
		return false
	}
	for _, q := range c.lits[1:] {
		if s.seen[q.Var()] == 0 && s.level[q.Var()] > 0 {
			return false
		}
	}
	return true
}

func (s *Solver) bumpVar(v Var) {
	s.activity[v] += s.varInc
	if s.activity[v] > varRescaleLimit {
		for i := range s.activity {
			s.activity[i] *= 1 / varRescaleLimit
		}
		s.varInc *= 1 / varRescaleLimit
	}
	s.order.increased(v)
}

func (s *Solver) bumpClause(c *clause) {
	c.activity += s.claInc
	if c.activity > clauseRescaleLim {
		for _, l := range s.learnts {
			l.activity *= 1 / clauseRescaleLim
		}
		s.claInc *= 1 / clauseRescaleLim
	}
}
