// Package engine evaluates a safe, stratified Datalog program bottom-up with
// semi-naive evaluation and answers queries over the resulting model.
//
// Constants are interned to dense integer ids assigned in the constant
// order, so the evaluator compares and hashes plain integers. Relations keep
// hash indexes per access pattern that are extended, never rebuilt. Each rule
// is compiled to an indexed nested-loop join plan; in recursive components a
// plan is produced for every recursive body atom, which reads the previous
// round's new tuples (the delta).
package engine

import (
	"slices"

	"example.com/datalog/ast"
)

// Tuple is a row of a relation.
type Tuple []ast.Constant

// Database holds the relations of an evaluated program.
type Database struct {
	syms  []ast.Constant // id -> constant, ascending in constant order
	symID map[ast.Constant]uint32
	rels  map[ast.PredID]*relation
}

// Evaluate computes the perfect model of prog. strata must list the
// components of the predicate dependency graph in evaluation order (see
// analysis.Stratify); prog must be safe.
func Evaluate(prog *ast.Program, strata [][]ast.PredID) *Database {
	db := &Database{symID: map[ast.Constant]uint32{}, rels: map[ast.PredID]*relation{}}
	db.intern(prog)

	byHead := map[ast.PredID][]ast.Rule{}
	for _, r := range prog.Rules {
		id := r.Head.ID()
		if len(r.Body) == 0 {
			row := make([]uint32, len(r.Head.Args))
			for i, t := range r.Head.Args {
				row[i] = db.symID[t.Const]
			}
			db.relation(id).insert(row)
		} else {
			byHead[id] = append(byHead[id], r)
		}
	}
	for _, comp := range strata {
		db.evalComponent(comp, byHead)
	}
	return db
}

// intern assigns ids to every constant of the program in constant order.
func (db *Database) intern(prog *ast.Program) {
	set := map[ast.Constant]bool{}
	atom := func(a ast.Atom) {
		for _, t := range a.Args {
			if !t.IsVar {
				set[t.Const] = true
			}
		}
	}
	for _, r := range prog.Rules {
		atom(r.Head)
		for _, l := range r.Body {
			switch l.Kind {
			case ast.Comparison:
				for _, t := range []ast.Term{l.Left, l.Right} {
					if !t.IsVar {
						set[t.Const] = true
					}
				}
			default:
				atom(l.Atom)
			}
		}
	}
	for _, q := range prog.Queries {
		atom(q)
	}
	for c := range set {
		db.syms = append(db.syms, c)
	}
	slices.SortFunc(db.syms, ast.Compare)
	for i, c := range db.syms {
		db.symID[c] = uint32(i)
	}
}

func (db *Database) relation(id ast.PredID) *relation {
	r, ok := db.rels[id]
	if !ok {
		r = newRelation(id.Arity)
		db.rels[id] = r
	}
	return r
}

func (db *Database) evalComponent(comp []ast.PredID, byHead map[ast.PredID][]ast.Rule) {
	inComp := map[ast.PredID]bool{}
	for _, id := range comp {
		inComp[id] = true
	}
	var base, variants []*plan
	for _, id := range comp {
		for _, r := range byHead[id] {
			base = append(base, db.compile(r, -1, nil))
			var recursive []bool
			for _, l := range r.Body {
				if l.Kind == ast.Positive {
					recursive = append(recursive, inComp[l.Atom.ID()])
				}
			}
			for k, rec := range recursive {
				if rec {
					variants = append(variants, db.compile(r, k, recursive))
				}
			}
		}
	}
	rels := make([]*relation, len(comp))
	for i, id := range comp {
		rels[i] = db.relation(id)
		rels[i].mark = rels[i].n
	}
	for _, p := range base {
		p.run()
	}
	for len(variants) > 0 {
		any := false
		for _, r := range rels {
			r.dlo, r.dhi, r.mark = r.mark, r.n, r.n
			any = any || r.dlo < r.dhi
		}
		if !any {
			break
		}
		for _, p := range variants {
			// The delta atom is the first step.
			if d := p.steps[0].rel; d.dlo < d.dhi {
				p.run()
			}
		}
	}
}

// Query returns the tuples of the model matching the pattern atom, in
// ascending tuple order: constants must match, and a variable occurring
// several times must match the same constant everywhere.
func (db *Database) Query(a ast.Atom) []Tuple {
	r, ok := db.rels[a.ID()]
	if !ok || r.n == 0 {
		return nil
	}
	var mask uint32
	var key []uint32
	firstAt := map[string]int{}
	type rep struct{ col, first int }
	var reps []rep
	for c, t := range a.Args {
		if !t.IsVar {
			id, ok := db.symID[t.Const]
			if !ok {
				return nil
			}
			mask |= 1 << c
			key = append(key, id)
		} else if f, ok := firstAt[t.Var]; ok {
			reps = append(reps, rep{c, f})
		} else {
			firstAt[t.Var] = c
		}
	}
	var ids []int
	consider := func(id int) {
		t := r.tuple(id)
		for _, p := range reps {
			if t[p.col] != t[p.first] {
				return
			}
		}
		ids = append(ids, id)
	}
	if mask == 0 {
		for id := 0; id < r.n; id++ {
			consider(id)
		}
	} else {
		ix := r.getIndex(mask)
		ix.sync(r)
		for h := ix.find(r, key); h != 0; h = ix.next[h-1] {
			consider(int(h - 1))
		}
	}
	slices.SortFunc(ids, func(x, y int) int { return slices.Compare(r.tuple(x), r.tuple(y)) })
	out := make([]Tuple, len(ids))
	for i, id := range ids {
		t := r.tuple(id)
		row := make(Tuple, len(t))
		for c, v := range t {
			row[c] = db.syms[v]
		}
		out[i] = row
	}
	return out
}

// Size returns the number of tuples in the relation with the given identity.
func (db *Database) Size(id ast.PredID) int {
	if r, ok := db.rels[id]; ok {
		return r.n
	}
	return 0
}
