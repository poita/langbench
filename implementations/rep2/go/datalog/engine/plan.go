package engine

import "example.com/datalog/ast"

// src is a value source: a variable slot (slot >= 0) or a constant id.
type src struct {
	slot int
	val  uint32
}

type colSlot struct{ col, slot int }

// role says which tuples of a relation a join step reads in a round.
type role int

const (
	roleFull  role = iota // everything present at the start of the round
	roleDelta             // only the previous round's new tuples
	roleOld               // everything before the previous round's tuples
)

// step is one positive atom of a join plan.
type step struct {
	rel     *relation
	role    role
	ix      *index // nil: scan the id range and check keyCols
	keyCols []int  // columns holding constants or already-bound variables
	keySrc  []src
	keyBuf  []uint32
	assign  []colSlot // columns binding new variables
	eq      []colSlot // columns repeating a variable bound earlier in this atom
	lo, hi  int       // id range for this run
}

// filter is a negated atom or comparison, evaluated as soon as its variables
// are bound.
type filter struct {
	neg         bool
	rel         *relation
	args        []src
	buf         []uint32
	op          ast.CmpOp
	left, right src
}

// plan is a compiled rule variant: an indexed nested-loop join over the
// positive atoms, with filters interleaved.
type plan struct {
	steps   []step
	filters [][]filter // filters[i] run once steps[:i] have bound their variables
	head    *relation
	headSrc []src
	headBuf []uint32
	binding []uint32
}

func (p *plan) val(s src) uint32 {
	if s.slot < 0 {
		return s.val
	}
	return p.binding[s.slot]
}

// compile builds the plan for rule r. deltaAtom is the position (among the
// rule's positive atoms, in body order) of the atom reading the delta, or -1
// to read every atom in full. recursive[k] tells whether positive atom k is
// in the rule's component; atoms of the component before deltaAtom read only
// old tuples so that each combination of new tuples is derived exactly once.
func (db *Database) compile(r ast.Rule, deltaAtom int, recursive []bool) *plan {
	slots := map[string]int{}
	slotOf := func(name string) int {
		s, ok := slots[name]
		if !ok {
			s = len(slots)
			slots[name] = s
		}
		return s
	}
	srcOf := func(t ast.Term) src {
		if t.IsVar {
			return src{slot: slotOf(t.Var)}
		}
		return src{slot: -1, val: db.symID[t.Const]}
	}

	var pos []ast.Atom
	var pending []filter
	var pendingVars [][]string
	for _, l := range r.Body {
		switch l.Kind {
		case ast.Positive:
			pos = append(pos, l.Atom)
		case ast.Negative:
			f := filter{neg: true, rel: db.relation(l.Atom.ID())}
			var vars []string
			for _, t := range l.Atom.Args {
				f.args = append(f.args, srcOf(t))
				if t.IsVar {
					vars = append(vars, t.Var)
				}
			}
			f.buf = make([]uint32, len(f.args))
			pending, pendingVars = append(pending, f), append(pendingVars, vars)
		case ast.Comparison:
			f := filter{op: l.Op, left: srcOf(l.Left), right: srcOf(l.Right)}
			var vars []string
			for _, t := range []ast.Term{l.Left, l.Right} {
				if t.IsVar {
					vars = append(vars, t.Var)
				}
			}
			pending, pendingVars = append(pending, f), append(pendingVars, vars)
		}
	}

	p := &plan{head: db.relation(r.Head.ID())}
	bound := map[string]bool{}
	attach := func() {
		var rest []filter
		var restVars [][]string
		at := make([]filter, 0)
		for i, f := range pending {
			ok := true
			for _, v := range pendingVars[i] {
				ok = ok && bound[v]
			}
			if ok {
				at = append(at, f)
			} else {
				rest, restVars = append(rest, f), append(restVars, pendingVars[i])
			}
		}
		p.filters = append(p.filters, at)
		pending, pendingVars = rest, restVars
	}
	attach()

	// Join order: the delta atom first, then repeatedly the atom with the
	// most bound arguments, ties broken by body order.
	used := make([]bool, len(pos))
	boundArgs := func(a ast.Atom) int {
		n := 0
		for _, t := range a.Args {
			if !t.IsVar || bound[t.Var] {
				n++
			}
		}
		return n
	}
	for len(p.steps) < len(pos) {
		pick := -1
		if len(p.steps) == 0 && deltaAtom >= 0 {
			pick = deltaAtom
		} else {
			best := -1
			for k, a := range pos {
				if !used[k] {
					if n := boundArgs(a); n > best {
						best, pick = n, k
					}
				}
			}
		}
		used[pick] = true
		a := pos[pick]
		s := step{rel: db.relation(a.ID()), role: roleFull}
		switch {
		case pick == deltaAtom:
			s.role = roleDelta
		case deltaAtom >= 0 && recursive[pick] && pick < deltaAtom:
			s.role = roleOld
		}
		var mask uint32
		seen := map[string]int{} // new variables of this atom -> slot
		for c, t := range a.Args {
			switch {
			case !t.IsVar:
				mask |= 1 << c
				s.keyCols = append(s.keyCols, c)
				s.keySrc = append(s.keySrc, srcOf(t))
			case bound[t.Var]:
				mask |= 1 << c
				s.keyCols = append(s.keyCols, c)
				s.keySrc = append(s.keySrc, src{slot: slotOf(t.Var)})
			default:
				if sl, ok := seen[t.Var]; ok {
					s.eq = append(s.eq, colSlot{c, sl})
				} else {
					sl = slotOf(t.Var)
					seen[t.Var] = sl
					s.assign = append(s.assign, colSlot{c, sl})
				}
			}
		}
		for v := range seen {
			bound[v] = true
		}
		if mask != 0 && s.role != roleDelta {
			s.ix = s.rel.getIndex(mask)
			s.keyBuf = make([]uint32, len(s.keyCols))
		}
		p.steps = append(p.steps, s)
		attach()
	}

	for _, t := range r.Head.Args {
		p.headSrc = append(p.headSrc, srcOf(t))
	}
	p.headBuf = make([]uint32, len(p.headSrc))
	p.binding = make([]uint32, len(slots))
	return p
}

// setRanges fixes the id range every step reads in the coming run.
func (p *plan) setRanges() {
	for i := range p.steps {
		s := &p.steps[i]
		switch s.role {
		case roleFull:
			s.lo, s.hi = 0, s.rel.n
		case roleDelta:
			s.lo, s.hi = s.rel.dlo, s.rel.dhi
		case roleOld:
			s.lo, s.hi = 0, s.rel.dlo
		}
		if s.ix != nil {
			s.ix.sync(s.rel)
		}
	}
}

func (p *plan) run() {
	p.setRanges()
	if p.check(0) {
		p.exec(0)
	}
}

func (p *plan) check(i int) bool {
	for k := range p.filters[i] {
		f := &p.filters[i][k]
		if f.neg {
			for j, a := range f.args {
				f.buf[j] = p.val(a)
			}
			if f.rel.contains(f.buf) {
				return false
			}
		} else {
			l, r := p.val(f.left), p.val(f.right)
			c := 0
			if l < r {
				c = -1
			} else if l > r {
				c = 1
			}
			if !f.op.Holds(c) {
				return false
			}
		}
	}
	return true
}

func (p *plan) exec(j int) {
	if j == len(p.steps) {
		for i, s := range p.headSrc {
			p.headBuf[i] = p.val(s)
		}
		p.head.insert(p.headBuf)
		return
	}
	s := &p.steps[j]
	if s.ix == nil {
		for id := s.lo; id < s.hi; id++ {
			p.visit(j, s, id, true)
		}
		return
	}
	for i, k := range s.keySrc {
		s.keyBuf[i] = p.val(k)
	}
	for h := s.ix.find(s.rel, s.keyBuf); h != 0; {
		id := int(h - 1)
		if id >= s.hi {
			break
		}
		p.visit(j, s, id, false)
		h = s.ix.next[id]
	}
}

func (p *plan) visit(j int, s *step, id int, checkKey bool) {
	t := s.rel.tuple(id)
	if checkKey {
		for i, c := range s.keyCols {
			if t[c] != p.val(s.keySrc[i]) {
				return
			}
		}
	}
	for _, a := range s.assign {
		p.binding[a.slot] = t[a.col]
	}
	for _, e := range s.eq {
		if t[e.col] != p.binding[e.slot] {
			return
		}
	}
	if p.check(j + 1) {
		p.exec(j + 1)
	}
}
