package engine

import (
	"slices"

	"datalog/analysis"
	"datalog/ast"
)

// Database holds the relations of an evaluated program.
type Database struct {
	prog *ast.Program
	rels []*Relation
}

// Relation returns the relation of predicate id p.
func (db *Database) Relation(p int) *Relation { return db.rels[p] }

// Evaluate computes the stratified model of p. The program must already have
// passed analysis.CheckSafety, and s must come from analysis.Stratify(p).
//
// Facts are loaded first. Components are then evaluated in dependency order: a
// non-recursive component runs each rule once; a recursive one runs every rule
// in round 0 and afterwards, per round, one delta variant of each rule per
// recursive positive body atom, until a round derives nothing new.
func Evaluate(p *ast.Program, s *analysis.Stratification) *Database {
	db := &Database{prog: p, rels: make([]*Relation, len(p.Preds))}
	for i, pr := range p.Preds {
		db.rels[i] = newRelation(pr.Arity)
	}
	byComp := make([][]*ast.Rule, len(s.Components))
	var tup []int32
	for i := range p.Rules {
		r := &p.Rules[i]
		if len(r.Body) == 0 {
			tup = tup[:0]
			for _, t := range r.Head.Args {
				tup = append(tup, int32(t.ID))
			}
			db.rels[r.Head.Pred].Add(tup)
			continue
		}
		c := s.Comp[r.Head.Pred]
		byComp[c] = append(byComp[c], r)
	}

	run := &runner{lo: make([]int, len(p.Preds)), hi: make([]int, len(p.Preds))}
	snapshot := func() {
		for i, r := range db.rels {
			run.hi[i] = r.n
		}
	}
	for c, rules := range byComp {
		if len(rules) == 0 {
			continue
		}
		var full []*plan
		type variant struct {
			pl   *plan
			pred int
		}
		var variants []variant
		for _, r := range rules {
			full = append(full, compile(db, r, -1))
			if !s.Recursive[c] {
				continue
			}
			for bi, l := range r.Body {
				if l.Kind == ast.Positive && s.Comp[l.Atom.Pred] == c {
					variants = append(variants, variant{compile(db, r, bi), l.Atom.Pred})
				}
			}
		}
		// Round 0: full plans. Later rounds: delta variants over the tuples
		// appended in the previous round.
		for round := 0; ; round++ {
			snapshot()
			if round == 0 {
				for _, pl := range full {
					run.run(pl)
				}
			} else {
				for _, v := range variants {
					if run.hi[v.pred] > run.lo[v.pred] {
						run.run(v.pl)
					}
				}
			}
			if !s.Recursive[c] {
				break
			}
			grew := false
			for _, pr := range s.Components[c] {
				if db.rels[pr].n > run.hi[pr] {
					grew = true
				}
			}
			if !grew {
				break
			}
			copy(run.lo, run.hi)
		}
	}
	return db
}

// Match returns the tuples of q's predicate that match the pattern, sorted in
// ascending tuple order. A constant argument must be equal to the tuple's
// component; a variable occurring several times must be bound to one value.
// The returned slices alias relation storage and must not be modified.
func (db *Database) Match(q ast.Atom) [][]int32 {
	rel := db.rels[q.Pred]
	var cols []int
	var key []int32
	var repeats [][2]int // pairs of columns that must be equal
	first := map[int]int{}
	for c, t := range q.Args {
		if !t.IsVar {
			cols = append(cols, c)
			key = append(key, int32(t.ID))
		} else if f, ok := first[t.ID]; ok {
			repeats = append(repeats, [2]int{f, c})
		} else {
			first[t.ID] = c
		}
	}
	var out [][]int32
	accept := func(t []int32) {
		for _, r := range repeats {
			if t[r[0]] != t[r[1]] {
				return
			}
		}
		out = append(out, t)
	}
	if len(cols) == 0 {
		for i := 0; i < rel.n; i++ {
			accept(rel.Tuple(i))
		}
	} else if len(cols) == len(q.Args) {
		if rel.Contains(key) {
			out = append(out, key)
		}
	} else {
		ix := rel.index(cols)
		ix.Update()
		for p := ix.first(key); p >= 0; p = ix.next[p] {
			accept(rel.Tuple(int(p)))
		}
	}
	slices.SortFunc(out, slices.Compare[[]int32])
	return out
}
