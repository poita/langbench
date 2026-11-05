package solver

import "sort"

// reduceDB deletes the less active half of the learnt clauses (keeping
// binary clauses) and rebuilds every watch list. It must be called at
// decision level 0, where no live reason can refer to a deleted clause.
func (s *Solver) reduceDB() {
	s.stats.Reductions++
	ls := s.learnts
	sort.SliceStable(ls, func(i, j int) bool { return ls[i].act < ls[j].act })
	half := len(ls) / 2
	kept := ls[:0]
	for i, c := range ls {
		if i < half && len(c.lits) > 2 {
			continue
		}
		kept = append(kept, c)
	}
	for i := len(kept); i < len(ls); i++ {
		ls[i] = nil
	}
	s.learnts = kept
	for _, l := range s.trail {
		s.reason[varOf(l)] = nil
	}
	for i := range s.watches {
		s.watches[i] = s.watches[i][:0]
	}
	for _, c := range s.clauses {
		s.attach(c)
	}
	for _, c := range s.learnts {
		s.attach(c)
	}
}
