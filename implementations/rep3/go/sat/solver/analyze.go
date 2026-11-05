package solver

// analyze derives the first-UIP learnt clause from the conflicting clause,
// leaves it in s.learntB (asserting literal in slot 0, a literal of the
// backjump level in slot 1) and returns the backjump level.
func (s *Solver) analyze(confl *clause) int {
	learnt := append(s.learntB[:0], 0)
	pathC := 0
	p := lit(-1)
	idx := len(s.trail) - 1
	cur := int32(s.decisionLevel())

	for {
		if confl.learnt {
			s.bumpClause(confl)
		}
		for _, q := range confl.lits {
			if q == p {
				continue
			}
			v := varOf(q)
			if s.seen[v] || s.level[v] == 0 {
				continue
			}
			s.seen[v] = true
			s.bumpVar(v)
			if s.level[v] >= cur {
				pathC++
			} else {
				learnt = append(learnt, q)
			}
		}
		for !s.seen[varOf(s.trail[idx])] {
			idx--
		}
		p = s.trail[idx]
		idx--
		confl = s.reason[varOf(p)]
		s.seen[varOf(p)] = false
		pathC--
		if pathC <= 0 {
			break
		}
	}
	learnt[0] = p ^ 1

	// Local minimisation. seen keeps marking every literal of the unminimised
	// clause (dropped ones too) until the clean-up below.
	toClear := append(s.toClear[:0], learnt...)
	j := 1
	for i := 1; i < len(learnt); i++ {
		q := learnt[i]
		r := s.reason[varOf(q)]
		keep := r == nil
		if !keep {
			for _, x := range r.lits {
				v := varOf(x)
				if v == varOf(q) {
					continue
				}
				if !s.seen[v] && s.level[v] != 0 {
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
	for _, q := range toClear {
		s.seen[varOf(q)] = false
	}
	s.toClear = toClear

	bt := 0
	if len(learnt) > 1 {
		mi := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[varOf(learnt[i])] > s.level[varOf(learnt[mi])] {
				mi = i
			}
		}
		learnt[1], learnt[mi] = learnt[mi], learnt[1]
		bt = int(s.level[varOf(learnt[1])])
	}
	s.learntB = learnt
	return bt
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
		for _, l := range s.learnts {
			l.act *= 1e-20
		}
		s.claInc *= 1e-20
	}
}
