package engine

import (
	"slices"

	"example.com/datalog/analysis"
	"example.com/datalog/ast"
)

// DB is the computed model of a program: one relation per predicate.
type DB struct {
	rels map[ast.Pred]*relation
	syms *symtab
}

// Evaluate computes the perfect model of rules. comps must be the result of
// analysis.Stratify(rules), and the rules must have passed
// analysis.CheckSafety. Facts are rules with empty bodies.
func Evaluate(rules []ast.Rule, comps []analysis.Component) *DB {
	db := &DB{rels: make(map[ast.Pred]*relation), syms: newSymtab(rules)}
	rel := func(p ast.Pred) *relation {
		r, ok := db.rels[p]
		if !ok {
			r = newRelation(p.Arity)
			db.rels[p] = r
		}
		return r
	}
	byHead := make(map[ast.Pred][]ast.Rule)
	for _, r := range rules {
		rel(r.Head.Pred())
		for _, l := range r.Body {
			if l.Kind != ast.Comparison {
				rel(l.Atom.Pred())
			}
		}
		if r.IsFact() {
			t := make([]int32, len(r.Head.Args))
			for i, a := range r.Head.Args {
				t[i], _ = db.syms.id(a.Value)
			}
			rel(r.Head.Pred()).insert(t)
		} else {
			byHead[r.Head.Pred()] = append(byHead[r.Head.Pred()], r)
		}
	}
	for _, c := range comps {
		var rs []ast.Rule
		for _, p := range c.Preds {
			rs = append(rs, byHead[p]...)
		}
		db.evalComponent(c, rs)
	}
	return db
}

func (db *DB) syncAll() {
	for _, r := range db.rels {
		r.sync()
	}
}

// evalComponent runs the rules of one strongly connected component to a
// fixpoint. Rules without atoms of the component run once; the others run
// semi-naively: in each round, one variant per recursive atom reads that atom
// from the previous round's new tuples and every other atom from the
// relations as they stood at the start of the round.
func (db *DB) evalComponent(c analysis.Component, rules []ast.Rule) {
	inComp := make(map[ast.Pred]bool, len(c.Preds))
	for _, p := range c.Preds {
		inComp[p] = true
	}
	var base, rec []*plan
	for _, r := range rules {
		var recAtoms []int
		for i, l := range r.Body {
			if l.Kind == ast.Positive && inComp[l.Atom.Pred()] {
				recAtoms = append(recAtoms, i)
			}
		}
		if len(recAtoms) == 0 {
			base = append(base, db.compile(r, -1))
		}
		for _, i := range recAtoms {
			rec = append(rec, db.compile(r, i))
		}
	}

	db.syncAll()
	for _, p := range base {
		p.run()
	}
	if len(rec) == 0 {
		return
	}
	comp := make([]*relation, len(c.Preds))
	for i, p := range c.Preds {
		comp[i] = db.rels[p]
		comp[i].dlo, comp[i].dhi = 0, comp[i].n
		comp[i].sync()
	}
	for {
		empty := true
		for _, r := range comp {
			if r.dhi > r.dlo {
				empty = false
			}
		}
		if empty {
			return
		}
		for _, p := range rec {
			p.run()
		}
		for _, r := range comp {
			r.dlo, r.dhi = r.dhi, r.n
			r.sync()
		}
	}
}

func (p *plan) run() {
	for i := range p.pre {
		if !p.pre[i].holds(p.slots) {
			return
		}
	}
	p.exec(0)
}

func (a arg) value(slots []int32) int32 {
	if a.kind == aConst {
		return a.v
	}
	return slots[a.v]
}

func (f *filter) holds(slots []int32) bool {
	if f.negated {
		for i, a := range f.args {
			f.buf[i] = a.value(slots)
		}
		return f.rel.find(f.buf) < 0
	}
	l, r := f.l.value(slots), f.r.value(slots)
	c := 0
	if l < r {
		c = -1
	} else if l > r {
		c = 1
	}
	return f.op.Holds(c)
}

func (p *plan) exec(i int) {
	if i == len(p.steps) {
		for k, a := range p.headArgs {
			p.buf[k] = a.value(p.slots)
		}
		p.head.insert(p.buf)
		return
	}
	s := &p.steps[i]
	rel := s.rel
	switch {
	case s.delta:
		for id := rel.dlo; id < rel.dhi; id++ {
			p.try(i, s, id)
		}
	case s.full:
		for k, a := range s.args {
			s.buf[k] = a.value(p.slots)
		}
		if id := rel.find(s.buf); id >= 0 && id < rel.synced {
			p.next(i, s)
		}
	case s.ix != nil:
		var h uint64
		for _, a := range s.keyArgs {
			h = mix(h, a.value(p.slots))
		}
		for e := s.ix.head(h); e != 0; e = s.ix.next[e-1] {
			p.try(i, s, int(e-1))
		}
	default:
		for id := 0; id < rel.synced; id++ {
			p.try(i, s, id)
		}
	}
}

// try matches tuple id against the step's arguments, binding new variables.
func (p *plan) try(i int, s *step, id int) {
	t := s.rel.tuple(id)
	slots := p.slots
	for k, a := range s.args {
		switch a.kind {
		case aConst:
			if t[k] != a.v {
				return
			}
		case aWrite:
			slots[a.v] = t[k]
		default:
			if t[k] != slots[a.v] {
				return
			}
		}
	}
	p.next(i, s)
}

func (p *plan) next(i int, s *step) {
	for f := range s.filters {
		if !s.filters[f].holds(p.slots) {
			return
		}
	}
	p.exec(i + 1)
}

// Query returns the tuples of the predicate of atom that match its pattern:
// constants must be equal and a variable that occurs several times must bind
// to the same constant. Tuples are sorted in ascending order. A predicate
// that does not occur in the program is empty.
func (db *DB) Query(atom ast.Atom) [][]ast.Value {
	rel := db.rels[atom.Pred()]
	if rel == nil {
		return nil
	}
	consts := make([]int32, len(atom.Args))
	first := make([]int, len(atom.Args)) // earlier position of the same variable, or -1
	seen := map[string]int{}
	for i, t := range atom.Args {
		first[i] = -1
		if t.IsVar {
			if j, ok := seen[t.Name]; ok && !t.IsAnon() {
				first[i] = j
			} else {
				seen[t.Name] = i
			}
			consts[i] = -1
		} else {
			id, ok := db.syms.id(t.Value)
			if !ok {
				return nil
			}
			consts[i] = id
		}
	}
	var ids []int
	for id := 0; id < rel.n; id++ {
		t := rel.tuple(id)
		ok := true
		for i := range t {
			if consts[i] >= 0 && t[i] != consts[i] || first[i] >= 0 && t[i] != t[first[i]] {
				ok = false
				break
			}
		}
		if ok {
			ids = append(ids, id)
		}
	}
	slices.SortFunc(ids, func(a, b int) int { return slices.Compare(rel.tuple(a), rel.tuple(b)) })
	out := make([][]ast.Value, len(ids))
	for k, id := range ids {
		t := rel.tuple(id)
		row := make([]ast.Value, len(t))
		for i, c := range t {
			row[i] = db.syms.vals[c]
		}
		out[k] = row
	}
	return out
}

// Size returns the number of tuples of predicate p.
func (db *DB) Size(p ast.Pred) int {
	if r := db.rels[p]; r != nil {
		return r.n
	}
	return 0
}
