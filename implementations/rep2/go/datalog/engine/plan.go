package engine

import (
	"datalog/ast"
)

// src is a value source: a constant id or a slot in the variable environment.
type src struct {
	slot  bool
	value int32 // constant id, or slot number
}

func (s src) get(env []int32) int32 {
	if s.slot {
		return env[s.value]
	}
	return s.value
}

type stepMode uint8

const (
	modeScan  stepMode = iota // iterate a position range
	modeIndex                 // iterate an index bucket up to the snapshot
	modeProbe                 // membership test; every argument is bound
)

type check struct {
	pos int
	src src
}

type bind struct {
	pos  int
	slot int
}

type filterKind uint8

const (
	filterNot filterKind = iota
	filterCmp
)

// filter is a negated atom or a comparison, applied once all of its variables
// are bound.
type filter struct {
	kind filterKind
	rel  *Relation // filterNot
	args []src     // filterNot
	buf  []int32   // scratch tuple for filterNot
	op   ast.CmpOp // filterCmp
	l, r src       // filterCmp
}

// step joins one positive body atom.
type step struct {
	mode  stepMode
	pred  int
	rel   *Relation
	delta bool // scan only the previous round's delta range
	idx   *Index
	key   []src   // modeIndex: one per index column; modeProbe: the full tuple
	buf   []int32 // scratch for key / probe tuple
	pre   []check // scan: arguments that must equal a bound value
	binds []bind  // first occurrences of unbound variables
	post  []check // repeated unbound variables, checked after binding
	after []filter
}

// plan is a compiled join for one rule (or one delta variant of it).
type plan struct {
	head    *Relation
	headArg []src
	headBuf []int32
	pre     []filter // filters with no variables
	steps   []step
	nvars   int
	indexes []*Index
}

// compile builds the join plan for r. If delta >= 0 it is the body position of
// the positive atom that is scanned over the previous round's delta and joined
// first.
func compile(db *Database, r *ast.Rule, delta int) *plan {
	pl := &plan{head: db.rels[r.Head.Pred], nvars: r.NumVars}
	bound := make([]bool, r.NumVars)

	mk := func(t ast.Term) src { return src{slot: t.IsVar, value: int32(t.ID)} }
	allBound := func(ts ...ast.Term) bool {
		for _, t := range ts {
			if t.IsVar && !bound[t.ID] {
				return false
			}
		}
		return true
	}

	var pos []int // positive literals still to place
	for i, l := range r.Body {
		if l.Kind == ast.Positive && i != delta {
			pos = append(pos, i)
		}
	}
	var pending []int // filters not yet attached
	for i, l := range r.Body {
		if l.Kind != ast.Positive {
			pending = append(pending, i)
		}
	}
	makeFilter := func(l ast.Literal) filter {
		if l.Kind == ast.Negative {
			f := filter{kind: filterNot, rel: db.rels[l.Atom.Pred], buf: make([]int32, len(l.Atom.Args))}
			for _, t := range l.Atom.Args {
				f.args = append(f.args, mk(t))
			}
			return f
		}
		return filter{kind: filterCmp, op: l.Op, l: mk(l.Left), r: mk(l.Right)}
	}
	// attach moves every pending filter whose variables are all bound onto dst.
	attach := func(dst *[]filter) {
		rest := pending[:0]
		for _, i := range pending {
			l := r.Body[i]
			ok := false
			if l.Kind == ast.Negative {
				ok = allBound(l.Atom.Args...)
			} else {
				ok = allBound(l.Left, l.Right)
			}
			if ok {
				*dst = append(*dst, makeFilter(l))
			} else {
				rest = append(rest, i)
			}
		}
		pending = rest
	}
	attach(&pl.pre)

	place := func(bi int, isDelta bool) {
		a := r.Body[bi].Atom
		st := step{pred: a.Pred, rel: db.rels[a.Pred], delta: isDelta}
		var boundCols []int
		var boundSrc []src
		seen := map[int]bool{} // variables first bound within this atom
		for c, t := range a.Args {
			switch {
			case !t.IsVar:
				boundCols = append(boundCols, c)
				boundSrc = append(boundSrc, mk(t))
			case bound[t.ID]:
				boundCols = append(boundCols, c)
				boundSrc = append(boundSrc, mk(t))
			case seen[t.ID]:
				st.post = append(st.post, check{pos: c, src: mk(t)})
			default:
				seen[t.ID] = true
				st.binds = append(st.binds, bind{pos: c, slot: t.ID})
			}
		}
		switch {
		case isDelta:
			st.mode = modeScan
			for i, c := range boundCols {
				st.pre = append(st.pre, check{pos: c, src: boundSrc[i]})
			}
		case len(boundCols) == len(a.Args):
			st.mode = modeProbe
			st.key = boundSrc
			st.buf = make([]int32, len(a.Args))
		case len(boundCols) > 0:
			st.mode = modeIndex
			st.idx = st.rel.index(boundCols)
			st.key = boundSrc
			st.buf = make([]int32, len(boundCols))
			pl.indexes = append(pl.indexes, st.idx)
		default:
			st.mode = modeScan
		}
		for _, b := range st.binds {
			bound[b.slot] = true
		}
		attach(&st.after)
		pl.steps = append(pl.steps, st)
	}

	if delta >= 0 {
		place(delta, true)
	}
	for len(pos) > 0 {
		// Greedy: the atom with the most bound arguments; earliest on ties.
		best, bestScore := 0, -1
		for k, bi := range pos {
			score := 0
			for _, t := range r.Body[bi].Atom.Args {
				if !t.IsVar || bound[t.ID] {
					score++
				}
			}
			if score > bestScore {
				best, bestScore = k, score
			}
		}
		bi := pos[best]
		pos = append(pos[:best], pos[best+1:]...)
		place(bi, false)
	}

	for _, t := range r.Head.Args {
		pl.headArg = append(pl.headArg, mk(t))
	}
	pl.headBuf = make([]int32, len(r.Head.Args))
	return pl
}
