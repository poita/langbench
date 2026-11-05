package datalog

import "github.com/example/datalog/internal/store"

// Solve checks the program and computes its perfect model. It returns
// [ErrUnsafe] or [ErrNotStratifiable] (wrapped, test with errors.Is) if the
// program is rejected.
//
// Evaluation is bottom-up and semi-naive. The strongly connected components
// of the predicate dependency graph are processed in dependency order. A
// recursive component runs every rule once in full, then repeats delta
// variants of its rules, one per recursive body atom, each scanning only the
// tuples derived in the previous round, until a round derives nothing new.
func (p *Program) Solve() (*Model, error) {
	if err := p.checkSafety(); err != nil {
		return nil, err
	}
	st, err := p.stratify()
	if err != nil {
		return nil, err
	}

	rels := make([]*store.Relation, len(p.preds))
	for i, pi := range p.preds {
		rels[i] = store.NewRelation(pi.arity)
	}

	// Facts go straight into their relations; the remaining rules are
	// grouped by the component of their head.
	byComp := make([][]*rule, len(st.comps))
	tuple := make([]int32, 8)
	for i := range p.rules {
		r := &p.rules[i]
		if len(r.body) == 0 {
			t := tuple[:len(r.head.args)]
			for j, a := range r.head.args {
				t[j] = a.id
			}
			rels[r.head.pred].Insert(t)
			continue
		}
		c := st.compOf[r.head.pred]
		byComp[c] = append(byComp[c], r)
	}

	e := &executor{rels: rels}
	for c, rules := range byComp {
		if len(rules) > 0 {
			p.evalComponent(e, st, c, rules)
		}
	}
	return &Model{prog: p, rels: rels}, nil
}

// evalComponent computes the least fixpoint of the rules of component c.
func (p *Program) evalComponent(e *executor, st *strata, c int, rules []*rule) {
	type variant struct {
		pl   *plan
		rule *rule
	}
	var full []variant
	var deltas []variant
	for _, r := range rules {
		full = append(full, variant{compile(r, -1, e.rels), r})
		for bi, l := range r.body {
			if l.kind == litPos && st.compOf[l.atom.pred] == c {
				deltas = append(deltas, variant{compile(r, bi, e.rels), r})
			}
		}
	}

	// Round 0: every rule in full. Tuples appended by it form the first delta.
	dlo := make([]int, len(e.rels))
	dhi := make([]int, len(e.rels))
	for _, pred := range st.comps[c] {
		dlo[pred] = e.rels[pred].Len()
	}
	e.snapshot()
	for _, v := range full {
		e.run(v.pl, 0, 0)
		e.flush(v.pl.headRel)
	}
	if len(deltas) == 0 {
		return
	}

	// Semi-naive rounds. [dlo, dhi) is the delta of each predicate of the
	// component: the tuples appended by the previous round. Appends are
	// invisible to range scans and index lookups (they stop at the round's
	// snapshot), so the next delta is exactly [old size, new size) and every
	// tuple is a delta in exactly one round.
	for _, pred := range st.comps[c] {
		dhi[pred] = e.rels[pred].Len()
	}
	for {
		progress := false
		for _, pred := range st.comps[c] {
			if dlo[pred] != dhi[pred] {
				progress = true
			}
		}
		if !progress {
			return
		}
		e.snapshot()
		for _, v := range deltas {
			d := v.pl.deltaPred
			if dlo[d] == dhi[d] {
				continue
			}
			e.run(v.pl, dlo[d], dhi[d])
			e.flush(v.pl.headRel)
		}
		for _, pred := range st.comps[c] {
			dlo[pred] = dhi[pred]
			dhi[pred] = e.rels[pred].Len()
		}
	}
}
