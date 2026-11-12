// Package analysis performs the static checks on a program: rule safety and
// stratifiability. Stratify also computes the evaluation order.
package analysis

import (
	"errors"
	"fmt"

	"example.com/datalog/ast"
)

// ErrUnsafe is wrapped by the error CheckSafety returns.
var ErrUnsafe = errors.New("unsafe rule")

// ErrNotStratifiable is wrapped by the error Stratify returns.
var ErrNotStratifiable = errors.New("program is not stratifiable")

// CheckSafety verifies that in every rule each variable occurring in the
// head, in a negated atom or in a comparison also occurs in a positive body
// atom. A fact is safe only if its head is ground.
func CheckSafety(prog *ast.Program) error {
	for _, r := range prog.Rules {
		if err := checkRule(r); err != nil {
			return err
		}
	}
	return nil
}

func checkRule(r ast.Rule) error {
	bound := map[string]bool{}
	for _, l := range r.Body {
		if l.Kind == ast.Positive {
			for _, t := range l.Atom.Args {
				if t.IsVar {
					bound[t.Var] = true
				}
			}
		}
	}
	need := func(t ast.Term) error {
		if t.IsVar && !bound[t.Var] {
			return fmt.Errorf("%w: variable %s in %q occurs in no positive body atom", ErrUnsafe, t, r)
		}
		return nil
	}
	for _, t := range r.Head.Args {
		if err := need(t); err != nil {
			return err
		}
	}
	for _, l := range r.Body {
		switch l.Kind {
		case ast.Negative:
			for _, t := range l.Atom.Args {
				if err := need(t); err != nil {
					return err
				}
			}
		case ast.Comparison:
			if err := need(l.Left); err != nil {
				return err
			}
			if err := need(l.Right); err != nil {
				return err
			}
		}
	}
	return nil
}

// Stratify builds the predicate dependency graph, computes its strongly
// connected components with Tarjan's algorithm and returns them in
// evaluation order: every component appears after all components it depends
// on. The result contains every predicate mentioned anywhere in the program
// (including query-only predicates). It returns ErrNotStratifiable (wrapped)
// when a negative edge lies inside a component.
func Stratify(prog *ast.Program) ([][]ast.PredID, error) {
	index := map[ast.PredID]int{}
	var preds []ast.PredID
	node := func(a ast.Atom) int {
		id := a.ID()
		n, ok := index[id]
		if !ok {
			n = len(preds)
			index[id] = n
			preds = append(preds, id)
		}
		return n
	}
	type edge struct {
		to  int
		neg bool
	}
	var adj [][]edge
	grow := func() {
		for len(adj) < len(preds) {
			adj = append(adj, nil)
		}
	}
	for _, r := range prog.Rules {
		h := node(r.Head)
		for _, l := range r.Body {
			if l.Kind == ast.Comparison {
				continue
			}
			q := node(l.Atom)
			grow()
			// The head depends on the body predicate.
			adj[h] = append(adj[h], edge{q, l.Kind == ast.Negative})
		}
	}
	for _, q := range prog.Queries {
		node(q)
	}
	grow()

	// Tarjan: components are emitted after everything they depend on.
	n := len(preds)
	idx := make([]int, n)
	low := make([]int, n)
	on := make([]bool, n)
	comp := make([]int, n)
	for i := range idx {
		idx[i] = -1
	}
	var stack []int
	var comps [][]ast.PredID
	counter := 0
	var visit func(v int)
	visit = func(v int) {
		idx[v], low[v] = counter, counter
		counter++
		stack = append(stack, v)
		on[v] = true
		for _, e := range adj[v] {
			if idx[e.to] < 0 {
				visit(e.to)
				low[v] = min(low[v], low[e.to])
			} else if on[e.to] {
				low[v] = min(low[v], idx[e.to])
			}
		}
		if low[v] == idx[v] {
			var c []ast.PredID
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				on[w] = false
				comp[w] = len(comps)
				c = append(c, preds[w])
				if w == v {
					break
				}
			}
			comps = append(comps, c)
		}
	}
	for v := 0; v < n; v++ {
		if idx[v] < 0 {
			visit(v)
		}
	}
	for v := 0; v < n; v++ {
		for _, e := range adj[v] {
			if e.neg && comp[v] == comp[e.to] {
				return nil, fmt.Errorf("%w: %s depends negatively on %s within a cycle", ErrNotStratifiable, preds[v], preds[e.to])
			}
		}
	}
	return comps, nil
}
