package solver

// propagate performs unit propagation over the trail from qhead. It returns
// the conflicting clause, or nil if no conflict was found.
func (s *Solver) propagate() *clause {
	val := s.val
	for s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		s.stats.Propagations++
		fl := p ^ 1 // the literal that just became false
		ws := s.watches[fl]
		i, j := 0, 0
		var confl *clause
		for i < len(ws) {
			c := ws[i]
			i++
			ls := c.lits
			if ls[0] == fl {
				ls[0], ls[1] = ls[1], fl
			}
			if val[ls[0]] == lTrue {
				ws[j] = c
				j++
				continue
			}
			moved := false
			for k := 2; k < len(ls); k++ {
				if val[ls[k]] != lFalse {
					ls[1], ls[k] = ls[k], fl
					s.watches[ls[1]] = append(s.watches[ls[1]], c)
					moved = true
					break
				}
			}
			if moved {
				continue
			}
			ws[j] = c
			j++
			if val[ls[0]] == lFalse {
				confl = c
				for i < len(ws) {
					ws[j] = ws[i]
					j++
					i++
				}
				s.qhead = len(s.trail)
			} else {
				s.enqueue(ls[0], c)
			}
		}
		s.watches[fl] = ws[:j]
		if confl != nil {
			return confl
		}
	}
	return nil
}
