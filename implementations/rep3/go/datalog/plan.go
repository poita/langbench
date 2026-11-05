package datalog

import "github.com/example/datalog/internal/store"

// src is where a value comes from at run time: a constant or a variable slot.
type src struct {
	slot int32 // >= 0: variable slot; < 0: constant
	c    int32
}

func (s src) get(env []int32) int32 {
	if s.slot >= 0 {
		return env[s.slot]
	}
	return s.c
}

func toSrc(t term) src {
	if t.isVar {
		return src{slot: t.id}
	}
	return src{slot: -1, c: t.id}
}

type stepKind uint8

const (
	stScan  stepKind = iota // iterate a position range, checking bound positions
	stIndex                 // iterate the bucket of a hash index
	stProbe                 // every argument bound: one set-membership test
)

type check struct {
	pos int
	s   src
}

type bind struct {
	pos  int
	slot int32
}

// filter is a negated atom or a comparison, evaluated as soon as all its
// variables are bound.
type filter struct {
	neg  bool
	pred int32 // neg
	args []src // neg
	op   cmpOp // comparison
	l, r src
}

// step joins one positive body atom.
type step struct {
	kind   stepKind
	pred   int32
	rel    *store.Relation
	idx    *store.Index // stIndex
	key    []src        // stIndex: key components; stProbe: whole tuple
	checks []check      // stScan: positions bound by constants or earlier steps
	eqs    [][2]int     // positions that must equal an earlier position of the same atom
	binds  []bind       // positions that bind new variables
	after  []filter     // evaluated once this step has bound its variables
}

// plan is a compiled rule variant: a nested-loop join over steps.
type plan struct {
	numVars   int
	head      []src
	headPred  int32
	headRel   *store.Relation
	pre       []filter // filters needing no variables
	steps     []step
	deltaPred int32 // predicate scanned over its delta range by steps[0], or -1
	indexes   []*store.Index
}

// compile builds the plan for rule r. If delta >= 0 it is the body position
// of the positive atom that is scanned over the previous round's new tuples;
// that atom is joined first. Remaining atoms are ordered greedily by number of
// bound arguments, ties broken by body order.
func compile(r *rule, delta int, rels []*store.Relation) *plan {
	pl := &plan{numVars: r.numVars, headPred: r.head.pred, headRel: rels[r.head.pred], deltaPred: -1}
	for _, t := range r.head.args {
		pl.head = append(pl.head, toSrc(t))
	}

	var positives []int
	var pending []filter
	var pendingVars [][]int32
	for i, l := range r.body {
		switch l.kind {
		case litPos:
			positives = append(positives, i)
		case litNeg:
			f := filter{neg: true, pred: l.atom.pred}
			var vs []int32
			for _, t := range l.atom.args {
				f.args = append(f.args, toSrc(t))
				if t.isVar {
					vs = append(vs, t.id)
				}
			}
			pending, pendingVars = append(pending, f), append(pendingVars, vs)
		case litCmp:
			f := filter{op: l.op, l: toSrc(l.l), r: toSrc(l.r)}
			var vs []int32
			for _, t := range []term{l.l, l.r} {
				if t.isVar {
					vs = append(vs, t.id)
				}
			}
			pending, pendingVars = append(pending, f), append(pendingVars, vs)
		}
	}

	bound := make([]bool, r.numVars)
	// takeReady removes and returns the pending filters whose variables are bound.
	takeReady := func() []filter {
		var out []filter
		k := 0
		for i, f := range pending {
			ok := true
			for _, v := range pendingVars[i] {
				if !bound[v] {
					ok = false
					break
				}
			}
			if ok {
				out = append(out, f)
			} else {
				pending[k], pendingVars[k] = f, pendingVars[i]
				k++
			}
		}
		pending, pendingVars = pending[:k], pendingVars[:k]
		return out
	}
	pl.pre = takeReady()

	score := func(a atom) int {
		n := 0
		for _, t := range a.args {
			if !t.isVar || bound[t.id] {
				n++
			}
		}
		return n
	}

	for len(positives) > 0 {
		pick := 0
		if len(pl.steps) == 0 && delta >= 0 {
			for i, bi := range positives {
				if bi == delta {
					pick = i
				}
			}
		} else {
			best := -1
			for i, bi := range positives {
				if s := score(r.body[bi].atom); s > best {
					best, pick = s, i
				}
			}
		}
		bi := positives[pick]
		positives = append(positives[:pick], positives[pick+1:]...)
		a := r.body[bi].atom

		st := step{pred: a.pred, rel: rels[a.pred]}
		var keyCols []int
		var keySrc []src
		first := map[int32]int{} // variables bound by this atom -> first position
		for pos, t := range a.args {
			switch {
			case !t.isVar || bound[t.id]:
				keyCols = append(keyCols, pos)
				keySrc = append(keySrc, toSrc(t))
			default:
				if fp, ok := first[t.id]; ok {
					st.eqs = append(st.eqs, [2]int{pos, fp})
				} else {
					first[t.id] = pos
					st.binds = append(st.binds, bind{pos, t.id})
				}
			}
		}
		switch {
		case len(pl.steps) == 0 && delta >= 0:
			st.kind = stScan
			pl.deltaPred = a.pred
			for i, c := range keyCols {
				st.checks = append(st.checks, check{c, keySrc[i]})
			}
		case len(keyCols) == 0:
			st.kind = stScan
		case len(keyCols) == len(a.args):
			st.kind = stProbe
			st.key = keySrc
		default:
			st.kind = stIndex
			st.key = keySrc
			st.idx = st.rel.Index(keyCols)
			pl.indexes = append(pl.indexes, st.idx)
		}
		for _, b := range st.binds {
			bound[b.slot] = true
		}
		st.after = takeReady()
		pl.steps = append(pl.steps, st)
	}
	return pl
}
