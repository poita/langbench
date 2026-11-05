// Package graph builds the dependency graph of a plan.Build, validates it, and
// finds the set of steps reachable from the requested targets.
package graph

import (
	"strings"

	"buildsys/diag"
	"buildsys/plan"
)

// Files tells the graph which workspace files exist.
type Files interface {
	Exists(path string) bool
}

// Graph has one node per step (ids 0..S-1, equal to the step serial), one per
// phony target (ids S..S+P-1, in declaration order), and one per referenced
// source file (ids after that, created on demand).
type Graph struct {
	Build *plan.Build

	files    Files
	nSteps   int
	nPhonies int
	names    []string
	succ     [][]int // ordering dependencies, de-duplicated, first occurrence kept
	outIdx   map[string]int
	srcIdx   map[string]int
}

// Kind is the kind of a graph node.
type Kind uint8

// Node kinds.
const (
	StepNode Kind = iota
	PhonyNode
	SourceNode
)

// New builds the graph for b and performs whole-graph validation: duplicate
// outputs, then reference resolution (steps in serial order, then phony
// targets), then the default list.
func New(b *plan.Build, files Files) (*Graph, error) {
	g := &Graph{
		Build: b, files: files,
		nSteps: len(b.Steps), nPhonies: len(b.Phonies),
		outIdx: make(map[string]int, len(b.Steps)),
		srcIdx: make(map[string]int),
	}
	n := g.nSteps + g.nPhonies
	g.names = make([]string, n, n+16)
	g.succ = make([][]int, n, n+16)
	for i, s := range b.Steps {
		g.names[i] = s.Primary()
		for _, p := range s.FullOuts {
			if _, dup := g.outIdx[p]; dup {
				return nil, diag.New(diag.DupOutput, "%s", p)
			}
			g.outIdx[p] = i
		}
	}
	for i, p := range b.Phonies {
		g.names[g.nSteps+i] = "@" + p.Name
	}
	resolveAll := func(node int, refs ...[]string) error {
		var out []int
		dedup := make(map[int]struct{})
		owner := g.names[node]
		for _, list := range refs {
			for _, r := range list {
				t, ok := g.Resolve(r)
				if !ok {
					return diag.New(diag.MissingInput, "%s required by %s", r, owner)
				}
				if _, dup := dedup[t]; !dup {
					dedup[t] = struct{}{}
					out = append(out, t)
				}
			}
		}
		g.succ[node] = out
		return nil
	}
	for i, s := range b.Steps {
		if err := resolveAll(i, s.Ins, s.Afters); err != nil {
			return nil, err
		}
	}
	for i, p := range b.Phonies {
		if err := resolveAll(g.nSteps+i, p.Deps); err != nil {
			return nil, err
		}
	}
	for _, d := range b.Defaults {
		if _, ok := g.Resolve(d); !ok {
			return nil, diag.New(diag.UnknownTarget, "%s", d)
		}
	}
	return g, nil
}

// Resolve maps a target reference to a node: "@name" to a phony node; a path
// to the step that outputs it, else a source node if the file exists.
func (g *Graph) Resolve(ref string) (int, bool) {
	if strings.HasPrefix(ref, "@") {
		if i, ok := g.Build.PhonyIndex(ref[1:]); ok {
			return g.nSteps + i, true
		}
		return 0, false
	}
	if i, ok := g.outIdx[ref]; ok {
		return i, true
	}
	if i, ok := g.srcIdx[ref]; ok {
		return i, true
	}
	if !g.files.Exists(ref) {
		return 0, false
	}
	id := len(g.names)
	g.names = append(g.names, ref)
	g.succ = append(g.succ, nil)
	g.srcIdx[ref] = id
	return id, true
}

// NumNodes returns the current number of nodes.
func (g *Graph) NumNodes() int { return len(g.names) }

// NodeKind returns the kind of node n.
func (g *Graph) NodeKind(n int) Kind {
	switch {
	case n < g.nSteps:
		return StepNode
	case n < g.nSteps+g.nPhonies:
		return PhonyNode
	}
	return SourceNode
}

// Name returns the display name of node n: a step's primary output, "@" plus a
// phony name, or a source path.
func (g *Graph) Name(n int) string { return g.names[n] }

// Successors returns the ordering dependencies of node n.
func (g *Graph) Successors(n int) []int { return g.succ[n] }

// Step returns the step of a step node.
func (g *Graph) Step(n int) *plan.Step { return g.Build.Steps[n] }

// Requested resolves the requested targets: the given targets, or the default
// list when there are none, each de-duplicated keeping the first occurrence.
func (g *Graph) Requested(targets []string) ([]int, error) {
	list := targets
	if len(list) == 0 {
		list = g.Build.Defaults
	}
	if len(list) == 0 {
		return nil, diag.Bare(diag.NoDefault)
	}
	seen := make(map[string]struct{}, len(list))
	var roots []int
	for _, t := range list {
		if _, dup := seen[t]; dup {
			continue
		}
		seen[t] = struct{}{}
		n, ok := g.Resolve(t)
		if !ok {
			return nil, diag.New(diag.UnknownTarget, "%s", t)
		}
		roots = append(roots, n)
	}
	return roots, nil
}

type frame struct{ node, next int }

// Reach finds the nodes reachable from roots with the specification's
// iterative depth-first search. It returns E_CYCLE if the reachable subgraph
// has a cycle, and otherwise a boolean per node (indexed by node id) marking
// the reachable set.
func (g *Graph) Reach(roots []int) ([]bool, error) {
	const (
		white = iota
		grey
		black
	)
	colour := make([]uint8, len(g.names))
	for _, root := range roots {
		if colour[root] != white {
			continue
		}
		colour[root] = grey
		stack := []frame{{root, 0}}
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			succ := g.succ[top.node]
			if top.next < len(succ) {
				m := succ[top.next]
				top.next++
				if colour[m] == grey {
					j := 0
					for stack[j].node != m {
						j++
					}
					names := make([]string, 0, len(stack)-j+1)
					for _, f := range stack[j:] {
						names = append(names, g.names[f.node])
					}
					names = append(names, g.names[m])
					return nil, diag.New(diag.Cycle, "%s", strings.Join(names, " -> "))
				}
				if colour[m] == white {
					colour[m] = grey
					stack = append(stack, frame{m, 0})
				}
				continue
			}
			colour[top.node] = black
			stack = stack[:len(stack)-1]
		}
	}
	reach := make([]bool, len(colour))
	for i, c := range colour {
		reach[i] = c != white
	}
	return reach, nil
}
