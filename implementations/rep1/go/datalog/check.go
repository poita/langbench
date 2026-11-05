package datalog

import "fmt"

// Check verifies the static conditions of the language: every rule is safe
// ([ErrUnsafe]) and the program is stratifiable ([ErrNotStratifiable]).
// Safety is checked first.
func (p *Program) Check() error {
	_, err := p.analyze()
	return err
}

// component is a strongly connected component of the predicate dependency
// graph.
type component struct {
	preds     []int
	recursive bool // some rule's head and a positive body atom are both in it
}

// analyze checks safety and stratification and returns the components in
// evaluation order (every component after those it depends on).
func (p *Program) analyze() ([]component, error) {
	for i := range p.Rules {
		if err := p.Rules[i].checkSafe(); err != nil {
			return nil, err
		}
	}
	return p.stratify()
}

func (r *Rule) checkSafe() error {
	bound := make([]bool, r.NumVars)
	for _, l := range r.Body {
		if l.Kind == Positive {
			for _, t := range l.Atom.Args {
				if t.IsVar {
					bound[t.Index] = true
				}
			}
		}
	}
	ok := func(t Term) bool { return !t.IsVar || bound[t.Index] }
	unsafe := func(where string) error {
		return fmt.Errorf("%w: variable in %s at line %d is not bound by a positive body atom", ErrUnsafe, where, r.Line)
	}
	for _, t := range r.Head.Args {
		if !ok(t) {
			return unsafe("the head")
		}
	}
	for _, l := range r.Body {
		switch l.Kind {
		case Negative:
			for _, t := range l.Atom.Args {
				if !ok(t) {
					return unsafe("a negated atom")
				}
			}
		case Comparison:
			if !ok(l.Left) || !ok(l.Right) {
				return unsafe("a comparison")
			}
		}
	}
	return nil
}

type depEdge struct {
	to  int
	neg bool
}

// stratify computes the SCCs of the dependency graph with Tarjan's algorithm.
// Edges point from a rule's head to the predicates its body uses, so Tarjan
// emits a component only after all components it depends on: that is the
// evaluation order.
func (p *Program) stratify() ([]component, error) {
	n := len(p.Preds)
	adj := make([][]depEdge, n)
	for i := range p.Rules {
		r := &p.Rules[i]
		for _, l := range r.Body {
			if l.Kind != Comparison {
				adj[r.Head.Pred] = append(adj[r.Head.Pred], depEdge{l.Atom.Pred, l.Kind == Negative})
			}
		}
	}

	index := make([]int, n)
	low := make([]int, n)
	onStack := make([]bool, n)
	compOf := make([]int, n)
	for i := range index {
		index[i] = -1
	}
	var stack []int
	var comps []component
	counter := 0
	var visit func(v int)
	visit = func(v int) {
		index[v], low[v] = counter, counter
		counter++
		stack = append(stack, v)
		onStack[v] = true
		for _, e := range adj[v] {
			w := e.to
			if index[w] < 0 {
				visit(w)
				low[v] = min(low[v], low[w])
			} else if onStack[w] {
				low[v] = min(low[v], index[w])
			}
		}
		if low[v] == index[v] {
			c := component{}
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				compOf[w] = len(comps)
				c.preds = append(c.preds, w)
				if w == v {
					break
				}
			}
			comps = append(comps, c)
		}
	}
	for v := 0; v < n; v++ {
		if index[v] < 0 {
			visit(v)
		}
	}

	for v := 0; v < n; v++ {
		for _, e := range adj[v] {
			if compOf[v] != compOf[e.to] {
				continue
			}
			if e.neg {
				return nil, fmt.Errorf("%w: %s depends negatively on %s within a cycle",
					ErrNotStratifiable, p.Preds[v].Name, p.Preds[e.to].Name)
			}
			comps[compOf[v]].recursive = true
		}
	}
	return comps, nil
}
