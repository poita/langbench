package spreadsheet

// recalc brings every cell that depends on the edited cell root back up to
// date. It
//
//  1. collects the affected set A (root plus everything that transitively
//     reads it) with an iterative DFS over dependents lists, then
//  2. runs an iterative Tarjan SCC pass over the subgraph induced by A,
//     following dependency edges. Tarjan emits components dependencies-first,
//     so when a component is emitted the values it reads are already current.
//     A cyclic component gets #CYCLE!; any other cell is evaluated.
//
// No cell outside A is visited, and there is no cell-to-cell recursion.
func (s *Sheet) recalc(root int32) {
	s.gen++
	gen := s.gen

	s.affected = append(s.affected[:0], root)
	s.cells[root].mark = gen
	s.work = append(s.work[:0], root)
	for len(s.work) > 0 {
		v := s.work[len(s.work)-1]
		s.work = s.work[:len(s.work)-1]
		for _, r := range s.cells[v].rdeps {
			rc := &s.cells[r]
			if rc.mark != gen {
				rc.mark = gen
				s.affected = append(s.affected, r)
				s.work = append(s.work, r)
			}
		}
	}
	for _, h := range s.affected {
		c := &s.cells[h]
		c.tIdx, c.tLow, c.tPos, c.onStk = 0, 0, 0, false
	}

	counter := int32(0)
	visit := func(h int32) {
		counter++
		c := &s.cells[h]
		c.tIdx, c.tLow, c.tPos, c.onStk = counter, counter, 0, true
		s.stk = append(s.stk, h)
		s.work = append(s.work, h)
	}
	for _, r := range s.affected {
		if s.cells[r].tIdx != 0 {
			continue
		}
		s.stk = s.stk[:0]
		s.work = s.work[:0]
		visit(r)
		for len(s.work) > 0 {
			v := s.work[len(s.work)-1]
			c := &s.cells[v]
			if int(c.tPos) < len(c.deps) {
				w := c.deps[c.tPos]
				c.tPos++
				wc := &s.cells[w]
				if wc.mark != gen {
					continue
				}
				if wc.tIdx == 0 {
					visit(w)
				} else if wc.onStk && wc.tIdx < c.tLow {
					c.tLow = wc.tIdx
				}
				continue
			}
			s.work = s.work[:len(s.work)-1]
			if c.tLow == c.tIdx {
				s.scc = s.scc[:0]
				for {
					m := s.stk[len(s.stk)-1]
					s.stk = s.stk[:len(s.stk)-1]
					s.cells[m].onStk = false
					s.scc = append(s.scc, m)
					if m == v {
						break
					}
				}
				s.finishComponent()
			}
			if len(s.work) > 0 {
				p := &s.cells[s.work[len(s.work)-1]]
				if c.tLow < p.tLow {
					p.tLow = c.tLow
				}
			}
		}
	}
}

// finishComponent assigns values to the cells of the component in s.scc.
func (s *Sheet) finishComponent() {
	if len(s.scc) > 1 || s.cells[s.scc[0]].selfDep {
		cyc := ErrorValue(ErrCycle)
		for _, m := range s.scc {
			s.cells[m].val = cyc
		}
		return
	}
	c := &s.cells[s.scc[0]]
	if c.content == contentFormula {
		v := s.eval(c.expr, c.expr.Root)
		if v.kind == Empty {
			v = NumberValue(0)
		}
		c.val = v
	}
}
