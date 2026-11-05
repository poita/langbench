package engine

// runner executes compiled plans. It holds the per-round snapshot: hi[p] is
// the size of predicate p's relation when the round started, and lo[p] the
// size at the start of the previous round, so [lo,hi) is the round's delta.
type runner struct {
	lo, hi []int
	env    []int32
	out    []int32 // new head tuples found by the current run
	cur    *plan
}

// run executes pl against the current snapshot and then inserts the tuples it
// derived. It reports whether anything new was added. Relations never grow
// while a join is scanning them.
func (e *runner) run(pl *plan) bool {
	for _, ix := range pl.indexes {
		ix.Update()
	}
	if cap(e.env) < pl.nvars {
		e.env = make([]int32, pl.nvars)
	}
	e.env = e.env[:pl.nvars]
	e.out = e.out[:0]
	e.cur = pl
	if applyFilters(pl.pre, e.env) {
		e.step(0)
	}
	added := false
	w := len(pl.headBuf)
	for i := 0; i < len(e.out); i += w {
		if pl.head.Add(e.out[i : i+w]) {
			added = true
		}
	}
	return added
}

func applyFilters(fs []filter, env []int32) bool {
	for i := range fs {
		f := &fs[i]
		if f.kind == filterCmp {
			if !f.op.Holds(f.l.get(env), f.r.get(env)) {
				return false
			}
			continue
		}
		for j, a := range f.args {
			f.buf[j] = a.get(env)
		}
		if f.rel.Contains(f.buf) {
			return false
		}
	}
	return true
}

func (e *runner) emit() {
	pl := e.cur
	for i, a := range pl.headArg {
		pl.headBuf[i] = a.get(e.env)
	}
	if pl.head.Contains(pl.headBuf) {
		return
	}
	e.out = append(e.out, pl.headBuf...)
}

// visit binds the variables of tuple t for step s, checks it and continues.
func (e *runner) visit(i int, s *step, t []int32) {
	env := e.env
	for _, c := range s.pre {
		if t[c.pos] != c.src.get(env) {
			return
		}
	}
	for _, b := range s.binds {
		env[b.slot] = t[b.pos]
	}
	for _, c := range s.post {
		if t[c.pos] != c.src.get(env) {
			return
		}
	}
	if len(s.after) > 0 && !applyFilters(s.after, env) {
		return
	}
	e.step(i + 1)
}

func (e *runner) step(i int) {
	pl := e.cur
	if i == len(pl.steps) {
		e.emit()
		return
	}
	s := &pl.steps[i]
	env := e.env
	switch s.mode {
	case modeProbe:
		for j, k := range s.key {
			s.buf[j] = k.get(env)
		}
		if s.rel.Contains(s.buf) {
			if len(s.after) == 0 || applyFilters(s.after, env) {
				e.step(i + 1)
			}
		}
	case modeIndex:
		for j, k := range s.key {
			s.buf[j] = k.get(env)
		}
		hi := int32(e.hi[s.pred])
		ix := s.idx
		for p := ix.first(s.buf); p >= 0 && p < hi; p = ix.next[p] {
			e.visit(i, s, s.rel.Tuple(int(p)))
		}
	default:
		lo, hi := 0, e.hi[s.pred]
		if s.delta {
			lo = e.lo[s.pred]
		}
		for p := lo; p < hi; p++ {
			e.visit(i, s, s.rel.Tuple(p))
		}
	}
}
