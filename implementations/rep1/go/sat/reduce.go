package sat

import "sort"

// reduceDB deletes the lower-activity half of the learnt clauses, always
// keeping binary clauses. It must be called at decision level 0.
func (s *Solver) reduceDB() {
	s.stats.Reductions++
	sort.SliceStable(s.learnts, func(i, j int) bool {
		return s.learnts[i].act < s.learnts[j].act
	})
	half := len(s.learnts) / 2
	kept := s.learnts[:0]
	for i, c := range s.learnts {
		if i < half && len(c.lits) > 2 {
			c.deleted = true
		} else {
			kept = append(kept, c)
		}
	}
	for i := len(kept); i < len(s.learnts); i++ {
		s.learnts[i] = nil
	}
	s.learnts = kept
	for l, ws := range s.watches {
		j := 0
		for _, w := range ws {
			if !w.c.deleted {
				ws[j] = w
				j++
			}
		}
		for k := j; k < len(ws); k++ {
			ws[k] = watcher{}
		}
		s.watches[l] = ws[:j]
	}
}
