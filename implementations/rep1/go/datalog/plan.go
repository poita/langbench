package datalog

// A plan is a rule compiled for evaluation: a nested-loop join over the
// positive body atoms, driven by hash lookups, with negated atoms and
// comparisons attached as filters at the earliest step where all their
// variables are bound. Variables are integer slots.

// src is a value source: a variable slot (slot >= 0) or a constant id.
type src struct {
	slot int32
	c    int32
}

func constSrc(c int) src { return src{slot: -1, c: int32(c)} }
func slotSrc(s int) src  { return src{slot: int32(s)} }

type stepMode uint8

const (
	modeScan   stepMode = iota // iterate a position range
	modeLookup                 // hash-index lookup on the bound columns
	modeProbe                  // every argument bound: membership test
)

type opKind uint8

const (
	opBind       opKind = iota // slots[slot] = t[pos]
	opCheckSlot                // t[pos] == slots[slot]
	opCheckConst               // t[pos] == c
)

type op struct {
	kind opKind
	pos  int
	slot int32
	c    int32
}

type filter struct {
	negated bool
	// negated atom: its predicate and arguments
	pred int
	args []src
	// comparison
	cmp         CmpOp
	left, right src
}

type step struct {
	mode    stepMode
	pred    int
	arity   int
	delta   bool // scan only the previous round's new tuples
	idx     *index
	key     []src // lookup: key in column order; probe: the whole tuple
	ops     []op  // applied to each candidate tuple
	filters []filter
}

type plan struct {
	headPred int
	head     []src
	pre      []filter // filters with no variables, checked before the first step
	steps    []step
	numVars  int
	// delta is the body index of the delta atom, or -1 for the full plan.
	delta int
}

// compile builds the plan for rule r. If deltaLit >= 0 it is the body index of
// the positive atom that scans only the delta range.
func compile(r *Rule, deltaLit int, rels []*relation) *plan {
	p := &plan{headPred: r.Head.Pred, numVars: r.NumVars, delta: deltaLit}
	bound := make([]bool, r.NumVars)

	termSrc := func(t Term) src {
		if t.IsVar {
			return slotSrc(t.Index)
		}
		return constSrc(t.Index)
	}
	termBound := func(t Term) bool { return !t.IsVar || bound[t.Index] }
	allBound := func(l *Literal) bool {
		if l.Kind == Comparison {
			return termBound(l.Left) && termBound(l.Right)
		}
		for _, t := range l.Atom.Args {
			if !termBound(t) {
				return false
			}
		}
		return true
	}

	var positives, others []int
	for i := range r.Body {
		if r.Body[i].Kind == Positive {
			positives = append(positives, i)
		} else {
			others = append(others, i)
		}
	}
	placed := make([]bool, len(r.Body))
	// attach moves every not-yet-placed filter that is now fully bound into dst.
	attach := func(dst *[]filter) {
		for _, i := range others {
			l := &r.Body[i]
			if placed[i] || !allBound(l) {
				continue
			}
			placed[i] = true
			if l.Kind == Comparison {
				*dst = append(*dst, filter{cmp: l.Op, left: termSrc(l.Left), right: termSrc(l.Right)})
			} else {
				f := filter{negated: true, pred: l.Atom.Pred}
				for _, t := range l.Atom.Args {
					f.args = append(f.args, termSrc(t))
				}
				*dst = append(*dst, f)
			}
		}
	}
	attach(&p.pre)

	remaining := append([]int(nil), positives...)
	for len(remaining) > 0 {
		pick := -1
		if len(p.steps) == 0 && deltaLit >= 0 {
			for k, i := range remaining {
				if i == deltaLit {
					pick = k
				}
			}
		} else {
			best := -1
			for k, i := range remaining {
				n := 0
				for _, t := range r.Body[i].Atom.Args {
					if termBound(t) {
						n++
					}
				}
				if n > best {
					best, pick = n, k
				}
			}
		}
		bi := remaining[pick]
		remaining = append(remaining[:pick], remaining[pick+1:]...)
		a := r.Body[bi].Atom
		s := step{pred: a.Pred, arity: len(a.Args), delta: bi == deltaLit}

		nBound := 0
		for _, t := range a.Args {
			if termBound(t) {
				nBound++
			}
		}
		switch {
		case s.delta || nBound == 0:
			s.mode = modeScan
		case nBound == len(a.Args):
			s.mode = modeProbe
		default:
			s.mode = modeLookup
		}

		var cols uint64
		seen := make([]bool, r.NumVars) // variables bound within this atom
		for pos, t := range a.Args {
			isBound := termBound(t)
			switch {
			case s.mode == modeProbe:
				s.key = append(s.key, termSrc(t))
			case s.mode == modeLookup && isBound:
				cols |= 1 << pos
				s.key = append(s.key, termSrc(t))
			case !t.IsVar:
				s.ops = append(s.ops, op{kind: opCheckConst, pos: pos, c: int32(t.Index)})
			case isBound || seen[t.Index]:
				s.ops = append(s.ops, op{kind: opCheckSlot, pos: pos, slot: int32(t.Index)})
			default:
				seen[t.Index] = true
				s.ops = append(s.ops, op{kind: opBind, pos: pos, slot: int32(t.Index)})
			}
		}
		if s.mode == modeLookup {
			s.idx = rels[a.Pred].index(cols)
		}
		for _, t := range a.Args {
			if t.IsVar {
				bound[t.Index] = true
			}
		}
		attach(&s.filters)
		p.steps = append(p.steps, s)
	}

	for _, t := range r.Head.Args {
		p.head = append(p.head, termSrc(t))
	}
	return p
}
