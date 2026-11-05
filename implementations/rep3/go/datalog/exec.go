package datalog

import "github.com/example/datalog/internal/store"

// executor runs plans. Derived head tuples that are not already known are
// collected in out and inserted only after the run, so no relation grows
// while a join scans it.
type executor struct {
	rels []*store.Relation
	env  []int32
	tmp  [8]int32
	out  []int32 // flat head tuples of the current run
	pl   *plan
	lo   int // delta range of steps[0], when pl.deltaPred >= 0
	hi   int
	// limit[p] is the size of relation p when the current round began; scans
	// and index lookups stop there, so tuples appended mid-round stay invisible.
	limit []int
}

// snapshot records the current size of every relation as the round's limit.
func (e *executor) snapshot() {
	if e.limit == nil {
		e.limit = make([]int, len(e.rels))
	}
	for i, r := range e.rels {
		e.limit[i] = r.Len()
	}
}

// run executes pl. For a delta variant [lo, hi) is the range of the delta
// predicate that steps[0] scans; every other atom sees the relations as they
// are at the start of the run.
func (e *executor) run(pl *plan, lo, hi int) {
	for _, ix := range pl.indexes {
		ix.Update()
	}
	e.pl, e.lo, e.hi = pl, lo, hi
	if cap(e.env) < pl.numVars {
		e.env = make([]int32, pl.numVars)
	}
	e.env = e.env[:pl.numVars]
	if e.passFilters(pl.pre) {
		e.join(0)
	}
}

// flush inserts the buffered head tuples into the relation of the last run
// and reports whether any was new.
func (e *executor) flush(rel *store.Relation) bool {
	added := false
	a := rel.Arity()
	for i := 0; i < len(e.out); i += a {
		if rel.Insert(e.out[i : i+a]) {
			added = true
		}
	}
	e.out = e.out[:0]
	return added
}

func (e *executor) passFilters(fs []filter) bool {
	for i := range fs {
		f := &fs[i]
		if f.neg {
			t := e.tmp[:len(f.args)]
			for j, s := range f.args {
				t[j] = s.get(e.env)
			}
			if e.rels[f.pred].Contains(t) {
				return false
			}
		} else if !f.op.holds(f.l.get(e.env), f.r.get(e.env)) {
			return false
		}
	}
	return true
}

func (e *executor) join(si int) {
	pl := e.pl
	if si == len(pl.steps) {
		t := e.tmp[:len(pl.head)]
		for i, s := range pl.head {
			t[i] = s.get(e.env)
		}
		if !pl.headRel.Contains(t) {
			e.out = append(e.out, t...)
		}
		return
	}
	st := &pl.steps[si]
	switch st.kind {
	case stProbe:
		t := e.tmp[:len(st.key)]
		for i, s := range st.key {
			t[i] = s.get(e.env)
		}
		if st.rel.Contains(t) && e.passFilters(st.after) {
			e.join(si + 1)
		}
	case stIndex:
		var key [8]int32
		k := key[:len(st.key)]
		for i, s := range st.key {
			k[i] = s.get(e.env)
		}
		n := int32(e.limit[st.pred])
		for pos := st.idx.First(k); pos >= 0 && pos < n; pos = st.idx.Next(pos) {
			e.visit(si, st, st.rel.Tuple(int(pos)))
		}
	default:
		lo, hi := 0, e.limit[st.pred]
		if si == 0 && pl.deltaPred >= 0 {
			lo, hi = e.lo, e.hi
		}
	rows:
		for pos := lo; pos < hi; pos++ {
			row := st.rel.Tuple(pos)
			for _, c := range st.checks {
				if row[c.pos] != c.s.get(e.env) {
					continue rows
				}
			}
			e.visit(si, st, row)
		}
	}
}

// visit extends the environment with row, applies the step's equality checks
// and filters, and continues with the next step.
func (e *executor) visit(si int, st *step, row []int32) {
	for _, q := range st.eqs {
		if row[q[0]] != row[q[1]] {
			return
		}
	}
	for _, b := range st.binds {
		e.env[b.slot] = row[b.pos]
	}
	if e.passFilters(st.after) {
		e.join(si + 1)
	}
}
