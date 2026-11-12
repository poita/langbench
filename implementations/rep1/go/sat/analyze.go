package sat

// analyze derives the first-UIP clause from a conflict at the current
// decision level. It returns the learnt clause, with the asserting literal
// first and a literal of the backjump level second, and the backjump level.
// The returned slice is only valid until the next call.
func (s *Solver) analyze(confl *clause) ([]lit, int) {
	learnt := append(s.learntBuf[:0], litUndef) // slot 0: asserting literal
	pathC := 0
	p := litUndef
	idx := len(s.trail) - 1
	for {
		if confl.learnt {
			s.bumpClause(confl)
		}
		start := 0
		if p != litUndef {
			start = 1 // lits[0] is the implied literal p itself
		}
		for _, q := range confl.lits[start:] {
			v := q.variable()
			if s.seen[v] || s.level[v] == 0 {
				continue
			}
			s.bumpVar(v)
			s.seen[v] = true
			if s.level[v] >= s.decisionLevel() {
				pathC++
			} else {
				learnt = append(learnt, q)
			}
		}
		for !s.seen[s.trail[idx].variable()] {
			idx--
		}
		p = s.trail[idx]
		idx--
		confl = s.reason[p.variable()]
		s.seen[p.variable()] = false
		pathC--
		if pathC <= 0 {
			break
		}
	}
	learnt[0] = p.neg()

	// Local minimisation: drop a literal whose reason is entirely made of
	// literals already in the clause (or fixed at the root).
	s.toClear = append(s.toClear[:0], learnt...)
	j := 1
	for i := 1; i < len(learnt); i++ {
		if !s.redundant(learnt[i]) {
			learnt[j] = learnt[i]
			j++
		}
	}
	learnt = learnt[:j]
	for _, l := range s.toClear {
		s.seen[l.variable()] = false
	}

	bt := 0
	if len(learnt) > 1 {
		maxI := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[learnt[i].variable()] > s.level[learnt[maxI].variable()] {
				maxI = i
			}
		}
		learnt[1], learnt[maxI] = learnt[maxI], learnt[1]
		bt = s.level[learnt[1].variable()]
	}
	s.learntBuf = learnt
	return learnt, bt
}

// redundant reports whether l (a literal of the learnt clause) is implied by
// the other literals of the clause through its reason clause alone.
func (s *Solver) redundant(l lit) bool {
	r := s.reason[l.variable()]
	if r == nil {
		return false
	}
	for _, q := range r.lits[1:] {
		v := q.variable()
		if !s.seen[v] && s.level[v] > 0 {
			return false
		}
	}
	return true
}

func (s *Solver) bumpVar(v int) {
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
	c.act += s.claInc
	if c.act > claRescaleLimit {
		for _, d := range s.learnts {
			d.act *= 1 / claRescaleLimit
		}
		s.claInc *= 1 / claRescaleLimit
	}
}
