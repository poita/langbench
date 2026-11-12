package sat

import "sort"

// luby returns the i-th (from 0) element of the Luby sequence
// 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ... for base 2.
func luby(i int) int {
	size, seq := 1, 0
	for size < i+1 {
		seq++
		size = 2*size + 1
	}
	for size-1 != i {
		size = (size - 1) >> 1
		seq--
		i %= size
	}
	return 1 << seq
}

// locked reports whether c is the reason for its first literal's assignment.
func (s *Solver) locked(c *clause) bool {
	l := c.lits[0]
	return s.value(l) == lTrue && s.reason[l.Var()] == c
}

// reduceDB deletes the lower-activity half of the learnt clauses, keeping
// binary clauses and clauses that are currently reasons.
func (s *Solver) reduceDB() {
	s.stats.Reductions++
	sort.SliceStable(s.learnts, func(i, j int) bool {
		return s.learnts[i].activity < s.learnts[j].activity
	})
	half := len(s.learnts) / 2
	dead := make(map[*clause]struct{}, half)
	kept := s.learnts[:0]
	for i, c := range s.learnts {
		if i < half && len(c.lits) > 2 && !s.locked(c) {
			dead[c] = struct{}{}
		} else {
			kept = append(kept, c)
		}
	}
	for i := len(kept); i < len(s.learnts); i++ {
		s.learnts[i] = nil
	}
	s.learnts = kept
	if len(dead) == 0 {
		return
	}
	for l, ws := range s.watches {
		j := 0
		for _, w := range ws {
			if _, d := dead[w.c]; !d {
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
