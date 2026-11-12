package sat

// propagate performs unit propagation with two watched literals until a
// fixed point, returning a conflicting clause or nil.
//
// watches[p] lists the clauses watching ¬p; it is scanned when p becomes
// true. Each watcher carries a "blocker" literal: if it is true the clause is
// satisfied and need not be touched.
func (s *Solver) propagate() *clause {
	var confl *clause
	for confl == nil && s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		s.stats.Propagations++
		falseLit := p.neg()
		ws := s.watches[p]
		i, j := 0, 0
		for i < len(ws) {
			w := ws[i]
			i++
			if s.vals[w.blocker] == valTrue {
				ws[j] = w
				j++
				continue
			}
			c := w.c
			if c.lits[0] == falseLit {
				c.lits[0], c.lits[1] = c.lits[1], falseLit
			}
			first := c.lits[0]
			nw := watcher{c, first}
			if first != w.blocker && s.vals[first] == valTrue {
				ws[j] = nw
				j++
				continue
			}
			moved := false
			for k := 2; k < len(c.lits); k++ {
				if s.vals[c.lits[k]] != valFalse {
					c.lits[1], c.lits[k] = c.lits[k], falseLit
					n := c.lits[1].neg()
					s.watches[n] = append(s.watches[n], nw)
					moved = true
					break
				}
			}
			if moved {
				continue
			}
			ws[j] = nw
			j++
			if s.vals[first] == valFalse {
				confl = c
				s.qhead = len(s.trail)
				for i < len(ws) {
					ws[j] = ws[i]
					i++
					j++
				}
			} else {
				s.enqueue(first, c)
			}
		}
		s.watches[p] = ws[:j]
	}
	return confl
}
