package analysis

import (
	"fmt"
	"slices"

	"example.com/datalog/ast"
)

// Component is a strongly connected component of the predicate dependency
// graph: a set of mutually recursive predicates (or a single predicate).
type Component struct {
	Preds []ast.Pred
	// Recursive is true if some predicate of the component depends on a
	// predicate of the component (including itself).
	Recursive bool
}

// NotStratifiableError reports a cycle through a negative edge.
type NotStratifiableError struct {
	// From is the negated predicate and To the head of the rule using it;
	// they lie in the same strongly connected component.
	From, To ast.Pred
}

func (e *NotStratifiableError) Error() string {
	return fmt.Sprintf("program is not stratifiable: %s depends negatively on %s through a recursive cycle", e.To, e.From)
}

// Stratify builds the predicate dependency graph of rules, finds its strongly
// connected components with Tarjan's algorithm and returns them in
// evaluation order: every component comes after all components it depends
// on. It returns a *NotStratifiableError if a negative edge lies on a cycle.
// Only predicates that occur in some rule (head or body) are returned.
func Stratify(rules []ast.Rule) ([]Component, error) {
	id := make(map[ast.Pred]int)
	var preds []ast.Pred
	node := func(p ast.Pred) int {
		n, ok := id[p]
		if !ok {
			n = len(preds)
			id[p] = n
			preds = append(preds, p)
		}
		return n
	}
	type edge struct {
		to  int
		neg bool
	}
	var adj [][]edge // adj[q] lists the predicates that depend on q
	grow := func() {
		for len(adj) < len(preds) {
			adj = append(adj, nil)
		}
	}
	type negEdge struct{ from, to int }
	var negs []negEdge
	selfLoop := map[int]bool{}
	for _, r := range rules {
		h := node(r.Head.Pred())
		for _, l := range r.Body {
			if l.Kind == ast.Comparison {
				continue
			}
			q := node(l.Atom.Pred())
			grow()
			neg := l.Kind == ast.Negative
			adj[q] = append(adj[q], edge{h, neg})
			if neg {
				negs = append(negs, negEdge{q, h})
			}
			if q == h {
				selfLoop[q] = true
			}
		}
	}
	grow()

	// Tarjan's algorithm.
	n := len(preds)
	index := make([]int, n)
	low := make([]int, n)
	onStack := make([]bool, n)
	comp := make([]int, n)
	for i := range index {
		index[i] = -1
	}
	var stack []int
	var comps [][]int
	counter := 0
	var strong func(v int)
	strong = func(v int) {
		index[v], low[v] = counter, counter
		counter++
		stack = append(stack, v)
		onStack[v] = true
		for _, e := range adj[v] {
			w := e.to
			if index[w] < 0 {
				strong(w)
				low[v] = min(low[v], low[w])
			} else if onStack[w] {
				low[v] = min(low[v], index[w])
			}
		}
		if low[v] == index[v] {
			var c []int
			for {
				w := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[w] = false
				comp[w] = len(comps)
				c = append(c, w)
				if w == v {
					break
				}
			}
			comps = append(comps, c)
		}
	}
	for v := 0; v < n; v++ {
		if index[v] < 0 {
			strong(v)
		}
	}

	for _, e := range negs {
		if comp[e.from] == comp[e.to] {
			return nil, &NotStratifiableError{From: preds[e.from], To: preds[e.to]}
		}
	}

	// Tarjan emits a component after everything reachable from it, i.e. after
	// its dependents; reverse for dependency order.
	out := make([]Component, 0, len(comps))
	for i := len(comps) - 1; i >= 0; i-- {
		c := comps[i]
		slices.Sort(c)
		cc := Component{Recursive: len(c) > 1 || selfLoop[c[0]]}
		for _, v := range c {
			cc.Preds = append(cc.Preds, preds[v])
		}
		out = append(out, cc)
	}
	return out, nil
}
