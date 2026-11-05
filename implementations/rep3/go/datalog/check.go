package datalog

import (
	"errors"
	"fmt"
)

// Errors reported by [Program.Solve] and [Program.Check]. Test for them with
// errors.Is.
var (
	// ErrUnsafe: a variable of a rule's head, negated atom or comparison does
	// not occur in a positive body atom of that rule.
	ErrUnsafe = errors.New("datalog: unsafe rule")
	// ErrNotStratifiable: a dependency cycle contains a negative edge.
	ErrNotStratifiable = errors.New("datalog: program is not stratifiable")
)

// Check reports whether the program is safe (ErrUnsafe) and stratifiable
// (ErrNotStratifiable), in that order.
func (p *Program) Check() error {
	if err := p.checkSafety(); err != nil {
		return err
	}
	_, err := p.stratify()
	return err
}

func (p *Program) predName(id int32) string {
	return fmt.Sprintf("%s/%d", p.preds[id].name, p.preds[id].arity)
}

// checkSafety verifies that every variable of a head, negated atom or
// comparison occurs in a positive body atom of the same rule.
func (p *Program) checkSafety() error {
	var bound []bool
	for ri := range p.rules {
		r := &p.rules[ri]
		bound = append(bound[:0], make([]bool, r.numVars)...)
		for _, l := range r.body {
			if l.kind == litPos {
				for _, t := range l.atom.args {
					if t.isVar {
						bound[t.id] = true
					}
				}
			}
		}
		ok := func(ts ...term) bool {
			for _, t := range ts {
				if t.isVar && !bound[t.id] {
					return false
				}
			}
			return true
		}
		bad := !ok(r.head.args...)
		for _, l := range r.body {
			switch l.kind {
			case litNeg:
				bad = bad || !ok(l.atom.args...)
			case litCmp:
				bad = bad || !ok(l.l, l.r)
			}
		}
		if bad {
			return fmt.Errorf("%w: rule %d for %s", ErrUnsafe, ri+1, p.predName(r.head.pred))
		}
	}
	return nil
}

// stratify computes the strongly connected components of the predicate
// dependency graph, returned dependencies-first (a valid evaluation order),
// together with the component number of every predicate. A negative edge
// inside a component makes the program unstratifiable.
func (p *Program) stratify() (*strata, error) {
	n := len(p.preds)
	// Edges head -> body predicate: "head depends on body".
	adj := make([][]int32, n)
	type edge struct{ from, to int32 }
	var negEdges []edge
	for _, r := range p.rules {
		for _, l := range r.body {
			if l.kind == litCmp {
				continue
			}
			adj[r.head.pred] = append(adj[r.head.pred], l.atom.pred)
			if l.kind == litNeg {
				negEdges = append(negEdges, edge{r.head.pred, l.atom.pred})
			}
		}
	}

	// Tarjan's algorithm. Components are emitted after everything they
	// depend on, which is exactly bottom-up evaluation order.
	s := &strata{compOf: make([]int, n)}
	index := make([]int, n)
	low := make([]int, n)
	onStack := make([]bool, n)
	for i := range index {
		index[i] = -1
	}
	var stack []int32
	counter := 0
	var visit func(v int32)
	visit = func(v int32) {
		index[v], low[v] = counter, counter
		counter++
		stack = append(stack, v)
		onStack[v] = true
		for _, w := range adj[v] {
			if index[w] < 0 {
				visit(w)
				low[v] = min(low[v], low[w])
			} else if onStack[w] {
				low[v] = min(low[v], index[w])
			}
		}
		if low[v] == index[v] {
			c := len(s.comps)
			var comp []int32
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				s.compOf[w] = c
				comp = append(comp, w)
				if w == v {
					break
				}
			}
			s.comps = append(s.comps, comp)
		}
	}
	for v := int32(0); int(v) < n; v++ {
		if index[v] < 0 {
			visit(v)
		}
	}
	for _, e := range negEdges {
		if s.compOf[e.from] == s.compOf[e.to] {
			return nil, fmt.Errorf("%w: %s depends negatively on %s within a cycle",
				ErrNotStratifiable, p.predName(e.from), p.predName(e.to))
		}
	}
	return s, nil
}

// strata is the condensation of the predicate dependency graph.
type strata struct {
	comps  [][]int32 // dependencies first
	compOf []int     // predicate -> index into comps
}
