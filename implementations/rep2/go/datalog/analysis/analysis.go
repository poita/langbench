// Package analysis performs the static checks that precede evaluation: rule
// safety and stratification.
package analysis

import (
	"errors"
	"fmt"

	"datalog/ast"
)

// Sentinel errors returned (wrapped) by the checks.
var (
	// ErrUnsafe means some rule has a variable that no positive body atom binds.
	ErrUnsafe = errors.New("unsafe rule")
	// ErrNotStratifiable means a dependency cycle contains a negative edge.
	ErrNotStratifiable = errors.New("program is not stratifiable")
)

// CheckSafety verifies that in every rule each variable occurring in the head,
// in a negated atom or in a comparison also occurs in a positive body atom.
// Facts are rules with an empty body, so a fact containing a variable fails.
func CheckSafety(p *ast.Program) error {
	for i := range p.Rules {
		r := &p.Rules[i]
		bound := make([]bool, r.NumVars)
		for _, l := range r.Body {
			if l.Kind == ast.Positive {
				for _, t := range l.Atom.Args {
					if t.IsVar {
						bound[t.ID] = true
					}
				}
			}
		}
		check := func(t ast.Term) error {
			if t.IsVar && !bound[t.ID] {
				return fmt.Errorf("%w: rule %d (head %s): variable not bound by a positive body atom",
					ErrUnsafe, i+1, p.Preds[r.Head.Pred])
			}
			return nil
		}
		for _, t := range r.Head.Args {
			if err := check(t); err != nil {
				return err
			}
		}
		for _, l := range r.Body {
			switch l.Kind {
			case ast.Negative:
				for _, t := range l.Atom.Args {
					if err := check(t); err != nil {
						return err
					}
				}
			case ast.Comparison:
				if err := check(l.Left); err != nil {
					return err
				}
				if err := check(l.Right); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// Stratification is the result of Stratify: the strongly connected components
// of the predicate dependency graph in evaluation order.
type Stratification struct {
	// Components lists the predicates of each component. A component only
	// depends on components that appear earlier.
	Components [][]int
	// Comp maps a predicate id to the index of its component.
	Comp []int
	// Recursive reports whether a component contains a dependency cycle
	// (several predicates, or one predicate that depends on itself).
	Recursive []bool
}

// Stratify builds the predicate dependency graph, computes its strongly
// connected components (Tarjan) and rejects the program when a negative edge
// lies inside a component.
func Stratify(p *ast.Program) (*Stratification, error) {
	n := len(p.Preds)
	// Edges run from a rule's head predicate to the predicates of its body
	// atoms, so Tarjan emits dependencies before dependents.
	adj := make([][]int, n)
	type edge struct{ from, to int }
	var negs []edge
	selfLoop := make([]bool, n)
	for _, r := range p.Rules {
		h := r.Head.Pred
		for _, l := range r.Body {
			if l.Kind == ast.Comparison {
				continue
			}
			q := l.Atom.Pred
			adj[h] = append(adj[h], q)
			if q == h {
				selfLoop[h] = true
			}
			if l.Kind == ast.Negative {
				negs = append(negs, edge{h, q})
			}
		}
	}

	s := &Stratification{Comp: make([]int, n)}
	index := make([]int, n)
	low := make([]int, n)
	onStack := make([]bool, n)
	for i := range index {
		index[i] = -1
	}
	var stack []int
	counter := 0
	var visit func(v int)
	visit = func(v int) {
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
			var comp []int
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				s.Comp[w] = len(s.Components)
				comp = append(comp, w)
				if w == v {
					break
				}
			}
			s.Components = append(s.Components, comp)
			s.Recursive = append(s.Recursive, len(comp) > 1 || selfLoop[v])
		}
	}
	for v := 0; v < n; v++ {
		if index[v] < 0 {
			visit(v)
		}
	}
	for _, e := range negs {
		if s.Comp[e.from] == s.Comp[e.to] {
			return nil, fmt.Errorf("%w: %s depends negatively on %s within a cycle",
				ErrNotStratifiable, p.Preds[e.from], p.Preds[e.to])
		}
	}
	return s, nil
}
