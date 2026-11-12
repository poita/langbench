package engine

import "example.com/datalog/ast"

// A rule is compiled into join plans: one plan for rules without recursive
// atoms, and one plan per recursive positive atom (the delta atom) otherwise.
// A plan is an indexed nested-loop join over the positive atoms; negated atoms
// and comparisons are attached to the first step after which all of their
// variables are bound.

type argKind uint8

const (
	aConst argKind = iota // v is a constant id
	aRead                 // v is a slot bound earlier
	aWrite                // first occurrence of a variable: store into slot v
	aCheck                // repeat of a variable written earlier in the same atom
)

type arg struct {
	kind argKind
	v    int32
}

type filter struct {
	negated bool
	rel     *relation // negated atom's relation
	args    []arg
	buf     []int32
	op      ast.CmpOp
	l, r    arg
}

type step struct {
	rel     *relation
	args    []arg
	delta   bool   // iterate over the relation's delta range
	full    bool   // every argument is bound: a membership test
	ix      *index // non-nil if some but not all arguments are bound
	keyArgs []arg  // bound arguments, in column order, for the index key
	buf     []int32
	filters []filter
}

type plan struct {
	head     *relation
	headArgs []arg
	buf      []int32
	steps    []step
	pre      []filter // filters without variables
	slots    []int32
}

// compile builds the plan for rule with the positive literal at body position
// delta (or -1) as the delta atom.
func (db *DB) compile(rule ast.Rule, delta int) *plan {
	p := &plan{head: db.rels[rule.Head.Pred()]}
	slotOf := map[string]int32{}
	var pos, pending []int
	for i, l := range rule.Body {
		if l.Kind == ast.Positive {
			pos = append(pos, i)
		} else {
			pending = append(pending, i)
		}
	}

	boundArg := func(t ast.Term) arg {
		if t.IsVar {
			return arg{aRead, slotOf[t.Name]}
		}
		id, _ := db.syms.id(t.Value)
		return arg{aConst, id}
	}
	allBound := func(ts []ast.Term) bool {
		for _, t := range ts {
			if t.IsVar {
				if _, ok := slotOf[t.Name]; !ok {
					return false
				}
			}
		}
		return true
	}
	litTerms := func(l ast.Literal) []ast.Term {
		if l.Kind == ast.Comparison {
			return []ast.Term{l.Left, l.Right}
		}
		return l.Atom.Args
	}
	makeFilter := func(l ast.Literal) filter {
		if l.Kind == ast.Comparison {
			return filter{op: l.Op, l: boundArg(l.Left), r: boundArg(l.Right)}
		}
		f := filter{negated: true, rel: db.rels[l.Atom.Pred()]}
		for _, t := range l.Atom.Args {
			f.args = append(f.args, boundArg(t))
		}
		f.buf = make([]int32, len(f.args))
		return f
	}
	// attach moves every pending filter whose variables are all bound to dst.
	attach := func(dst *[]filter) {
		rest := pending[:0]
		for _, i := range pending {
			if allBound(litTerms(rule.Body[i])) {
				*dst = append(*dst, makeFilter(rule.Body[i]))
			} else {
				rest = append(rest, i)
			}
		}
		pending = rest
	}
	attach(&p.pre)

	remaining := pos
	pickAt := func(k int) int {
		i := remaining[k]
		remaining = append(remaining[:k:k], remaining[k+1:]...)
		return i
	}
	for len(remaining) > 0 {
		var litIdx int
		if len(p.steps) == 0 && delta >= 0 {
			for k, i := range remaining {
				if i == delta {
					litIdx = pickAt(k)
					break
				}
			}
		} else {
			best, bestN := 0, -1
			for k, i := range remaining {
				n := 0
				for _, t := range rule.Body[i].Atom.Args {
					if !t.IsVar {
						n++
					} else if _, ok := slotOf[t.Name]; ok {
						n++
					}
				}
				if n > bestN {
					best, bestN = k, n
				}
			}
			litIdx = pickAt(best)
		}

		atom := rule.Body[litIdx].Atom
		s := step{rel: db.rels[atom.Pred()], delta: litIdx == delta && len(p.steps) == 0}
		var mask uint32
		written := map[string]bool{}
		bound := 0
		for c, t := range atom.Args {
			switch {
			case !t.IsVar:
				s.args = append(s.args, boundArg(t))
				mask |= 1 << c
				s.keyArgs = append(s.keyArgs, s.args[c])
				bound++
			case written[t.Name]:
				s.args = append(s.args, arg{aCheck, slotOf[t.Name]})
			default:
				if sl, ok := slotOf[t.Name]; ok {
					s.args = append(s.args, arg{aRead, sl})
					mask |= 1 << c
					s.keyArgs = append(s.keyArgs, s.args[c])
					bound++
				} else {
					sl = int32(len(slotOf))
					slotOf[t.Name] = sl
					written[t.Name] = true
					s.args = append(s.args, arg{aWrite, sl})
				}
			}
		}
		s.buf = make([]int32, len(atom.Args))
		switch {
		case s.delta:
		case bound == len(atom.Args):
			s.full = true
		case bound > 0:
			s.ix = s.rel.indexFor(mask)
		}
		attach(&s.filters)
		p.steps = append(p.steps, s)
	}

	for _, t := range rule.Head.Args {
		p.headArgs = append(p.headArgs, boundArg(t))
	}
	p.buf = make([]int32, len(p.headArgs))
	p.slots = make([]int32, len(slotOf))
	return p
}
