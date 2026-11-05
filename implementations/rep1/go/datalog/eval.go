package datalog

// Model is the perfect model of a stratified program together with the program
// it was computed from.
type Model struct {
	prog  *Program
	rels  []*relation // by predicate id
	texts []string    // printed form of each constant id
}

// Evaluate checks prog (see [Program.Check]) and computes its stratified
// model with semi-naive bottom-up evaluation.
func Evaluate(prog *Program) (*Model, error) {
	comps, err := prog.analyze()
	if err != nil {
		return nil, err
	}
	m := &Model{prog: prog, rels: make([]*relation, len(prog.Preds))}
	for i, pr := range prog.Preds {
		m.rels[i] = newRelation(pr.Arity)
	}
	m.texts = make([]string, len(prog.Consts))
	for i, c := range prog.Consts {
		m.texts[i] = c.String()
	}

	// Facts go straight into their relations.
	var t []int32
	for i := range prog.Rules {
		r := &prog.Rules[i]
		if !r.IsFact() {
			continue
		}
		t = t[:0]
		for _, a := range r.Head.Args {
			t = append(t, int32(a.Index))
		}
		m.rels[r.Head.Pred].add(t)
	}

	rulesOf := make([][]*Rule, len(prog.Preds))
	maxVars, widest := 0, 0
	for i := range prog.Rules {
		r := &prog.Rules[i]
		maxVars = max(maxVars, r.NumVars)
		widest = max(widest, len(r.Head.Args))
		if !r.IsFact() {
			rulesOf[r.Head.Pred] = append(rulesOf[r.Head.Pred], r)
		}
	}
	for _, pr := range prog.Preds {
		widest = max(widest, pr.Arity)
	}
	ev := &evaluator{
		rels:    m.rels,
		slots:   make([]int32, maxVars),
		scratch: make([]int32, widest),
		key:     make([]int32, widest),
		lo:      make([]int, len(prog.Preds)),
		hi:      make([]int, len(prog.Preds)),
	}
	for _, c := range comps {
		ev.evalComponent(c, rulesOf)
	}
	return m, nil
}

// evaluator holds the mutable state of one evaluation run.
type evaluator struct {
	rels    []*relation
	slots   []int32
	scratch []int32 // tuple under construction (probes, negations, head)
	key     []int32 // index lookup key
	lo, hi  []int   // per predicate: delta range [lo,hi) and snapshot bound hi
	buf     []int32 // tuples derived by the current plan run, flat
	head    int     // predicate of the plan being run
	p       *plan
}

func (ev *evaluator) snapshot() {
	for i, r := range ev.rels {
		ev.hi[i] = r.n
	}
}

func (ev *evaluator) evalComponent(c component, rulesOf [][]*Rule) {
	var full, deltas []*plan
	for _, pr := range c.preds {
		for _, r := range rulesOf[pr] {
			full = append(full, compile(r, -1, ev.rels))
			if !c.recursive {
				continue
			}
			for i := range r.Body {
				l := &r.Body[i]
				if l.Kind == Positive && inComponent(c, l.Atom.Pred) {
					deltas = append(deltas, compile(r, i, ev.rels))
				}
			}
		}
	}
	if len(full) == 0 {
		return
	}

	// Round 0 (or the only round of a non-recursive component): full plans.
	ev.snapshot()
	for _, p := range full {
		ev.run(p)
	}
	if !c.recursive {
		return
	}

	// Semi-naive rounds. The delta of a round is what the previous round
	// appended: positions [lo, hi) where lo is the previous snapshot.
	for {
		copy(ev.lo, ev.hi)
		ev.snapshot()
		changed := false
		for _, pr := range c.preds {
			if ev.lo[pr] < ev.hi[pr] {
				changed = true
			}
		}
		if !changed {
			return
		}
		for _, p := range deltas {
			deltaPred := p.steps[0].pred
			if ev.lo[deltaPred] == ev.hi[deltaPred] {
				continue
			}
			ev.run(p)
		}
	}
}

func inComponent(c component, pred int) bool {
	for _, p := range c.preds {
		if p == pred {
			return true
		}
	}
	return false
}

// run executes one plan and then inserts the tuples it derived, so that no
// relation grows while a join is scanning it.
func (ev *evaluator) run(p *plan) {
	for i := range p.steps {
		if ix := p.steps[i].idx; ix != nil {
			ix.sync()
		}
	}
	ev.p = p
	ev.buf = ev.buf[:0]
	if ev.test(p.pre) {
		ev.exec(0)
	}
	rel := ev.rels[p.headPred]
	a := rel.arity
	for i := 0; i+a <= len(ev.buf); i += a {
		rel.add(ev.buf[i : i+a])
	}
}

func (ev *evaluator) val(s src) int32 {
	if s.slot >= 0 {
		return ev.slots[s.slot]
	}
	return s.c
}

// test reports whether all filters hold under the current bindings.
func (ev *evaluator) test(fs []filter) bool {
	for i := range fs {
		f := &fs[i]
		if f.negated {
			t := ev.scratch[:len(f.args)]
			for k, a := range f.args {
				t[k] = ev.val(a)
			}
			if ev.rels[f.pred].contains(t) {
				return false
			}
		} else if !f.cmp.holds(ev.val(f.left), ev.val(f.right)) {
			return false
		}
	}
	return true
}

func (ev *evaluator) emit() {
	p := ev.p
	t := ev.scratch[:len(p.head)]
	for i, h := range p.head {
		t[i] = ev.val(h)
	}
	if !ev.rels[p.headPred].contains(t) {
		ev.buf = append(ev.buf, t...)
	}
}

func (ev *evaluator) exec(i int) {
	p := ev.p
	if i == len(p.steps) {
		ev.emit()
		return
	}
	s := &p.steps[i]
	rel := ev.rels[s.pred]
	switch s.mode {
	case modeProbe:
		t := ev.scratch[:s.arity]
		for k, a := range s.key {
			t[k] = ev.val(a)
		}
		if rel.contains(t) && ev.test(s.filters) {
			ev.exec(i + 1)
		}
	case modeScan:
		lo, hi := 0, ev.hi[s.pred]
		if s.delta {
			lo = ev.lo[s.pred]
		}
		for pos := lo; pos < hi; pos++ {
			if ev.apply(s.ops, rel.tuple(pos)) && ev.test(s.filters) {
				ev.exec(i + 1)
			}
		}
	case modeLookup:
		key := ev.key[:len(s.key)]
		for k, a := range s.key {
			key[k] = ev.val(a)
		}
		hi := int32(ev.hi[s.pred])
		next := s.idx.next
		for pos := s.idx.find(key); pos >= 0 && pos < hi; pos = next[pos] {
			if ev.apply(s.ops, rel.tuple(int(pos))) && ev.test(s.filters) {
				ev.exec(i + 1)
			}
		}
	}
}

// apply binds new variables from t and checks constants and repeated
// variables; it reports whether t matches.
func (ev *evaluator) apply(ops []op, t []int32) bool {
	for i := range ops {
		o := &ops[i]
		switch o.kind {
		case opBind:
			ev.slots[o.slot] = t[o.pos]
		case opCheckSlot:
			if t[o.pos] != ev.slots[o.slot] {
				return false
			}
		default:
			if t[o.pos] != o.c {
				return false
			}
		}
	}
	return true
}
