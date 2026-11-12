package sat

// propagate performs unit propagation over the trail using two watched
// literals. It returns a conflicting clause, or nil if no conflict arose.
func (s *Solver) propagate() *clause {
	var confl *clause
	for s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		s.stats.Propagations++
		falseLit := p.Not()
		ws := s.watches[falseLit]
		i, j := 0, 0
		for i < len(ws) {
			w := ws[i]
			i++
			if s.value(w.blocker) == lTrue {
				ws[j] = w
				j++
				continue
			}
			c := w.c
			lits := c.lits
			// Make sure the false literal is lits[1].
			if lits[0] == falseLit {
				lits[0], lits[1] = lits[1], falseLit
			}
			first := lits[0]
			nw := watcher{c, first}
			if first != w.blocker && s.value(first) == lTrue {
				ws[j] = nw
				j++
				continue
			}
			moved := false
			for k := 2; k < len(lits); k++ {
				if s.value(lits[k]) != lFalse {
					lits[1], lits[k] = lits[k], falseLit
					s.watches[lits[1]] = append(s.watches[lits[1]], nw)
					moved = true
					break
				}
			}
			if moved {
				continue
			}
			ws[j] = nw
			j++
			if s.value(first) == lFalse {
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
		s.watches[falseLit] = ws[:j]
	}
	return confl
}
