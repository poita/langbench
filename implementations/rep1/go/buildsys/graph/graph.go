// Package graph builds the dependency graph of a plan: duplicate-output and
// reference validation, target resolution, deterministic cycle detection and
// reachability.
package graph

import (
	"strings"

	"buildsys/kerr"
	"buildsys/plan"
)

// Kind is the kind of a graph node.
type Kind uint8

// Node kinds.
const (
	Step Kind = iota
	Phony
	Source
)

// Node is a vertex of the graph. Step nodes occupy indices 0..S-1 equal to
// their serial numbers.
type Node struct {
	Kind Kind
	Name string     // primary output, "@"+phony name, or source path
	Step *plan.Step // for Step nodes
	Succ []int      // distinct ordering dependencies, first-occurrence order
}

// Files answers existence queries about the workspace.
type Files interface {
	Has(path string) bool
}

// Graph is the dependency graph of a plan.
type Graph struct {
	Nodes   []*Node
	plan    *plan.Plan
	files   Files
	owner   map[string]int // output path -> step node
	phonies map[string]int // phony name -> node
	sources map[string]int // source path -> node
}

// New validates the plan against the workspace and builds the graph. It performs,
// in order: duplicate output detection, reference resolution for every step and
// phony, and resolution of the default list.
func New(p *plan.Plan, files Files) (*Graph, error) {
	g := &Graph{
		plan:    p,
		files:   files,
		owner:   make(map[string]int),
		phonies: make(map[string]int),
		sources: make(map[string]int),
	}
	for _, s := range p.Steps {
		g.Nodes = append(g.Nodes, &Node{Kind: Step, Name: s.Primary(), Step: s})
	}
	for _, ph := range p.Phonies {
		g.phonies[ph.Name] = len(g.Nodes)
		g.Nodes = append(g.Nodes, &Node{Kind: Phony, Name: "@" + ph.Name})
	}
	for _, s := range p.Steps {
		for _, o := range s.AllOutputs() {
			if _, dup := g.owner[o]; dup {
				return nil, kerr.New(kerr.DupOutput, "%s", o)
			}
			g.owner[o] = s.Serial
		}
	}
	for _, s := range p.Steps {
		succ := make([]int, 0, len(s.Inputs)+len(s.After))
		for _, list := range [][]string{s.Inputs, s.After} {
			for _, ref := range list {
				n, ok := g.Resolve(ref)
				if !ok {
					return nil, kerr.New(kerr.MissingInput, "%s required by %s", ref, s.Primary())
				}
				succ = append(succ, n)
			}
		}
		g.Nodes[s.Serial].Succ = dedup(succ)
	}
	for _, ph := range p.Phonies {
		succ := make([]int, 0, len(ph.Deps))
		for _, ref := range ph.Deps {
			n, ok := g.Resolve(ref)
			if !ok {
				return nil, kerr.New(kerr.MissingInput, "%s required by @%s", ref, ph.Name)
			}
			succ = append(succ, n)
		}
		g.Nodes[g.phonies[ph.Name]].Succ = dedup(succ)
	}
	for _, d := range p.Defaults {
		if _, ok := g.Resolve(d); !ok {
			return nil, kerr.New(kerr.UnknownTarget, "%s", d)
		}
	}
	return g, nil
}

func dedup(xs []int) []int {
	seen := make(map[int]struct{}, len(xs))
	out := xs[:0]
	for _, x := range xs {
		if _, dup := seen[x]; !dup {
			seen[x] = struct{}{}
			out = append(out, x)
		}
	}
	return out
}

// Resolve maps a target reference to a node: a phony ("@name"), a step that
// outputs the path, or an existing source file.
func (g *Graph) Resolve(ref string) (int, bool) {
	if strings.HasPrefix(ref, "@") {
		n, ok := g.phonies[ref[1:]]
		return n, ok
	}
	if n, ok := g.owner[ref]; ok {
		return n, true
	}
	if n, ok := g.sources[ref]; ok {
		return n, true
	}
	if g.files.Has(ref) {
		n := len(g.Nodes)
		g.Nodes = append(g.Nodes, &Node{Kind: Source, Name: ref})
		g.sources[ref] = n
		return n, true
	}
	return 0, false
}

// Selection is the result of choosing the requested targets.
type Selection struct {
	Roots     []int  // requested target nodes in order, duplicates removed
	Reachable []bool // indexed by node
}

// Select determines the requested targets (the given ones, or the default
// list when none are given), resolves them, checks the reachable part of the
// graph for cycles and computes the reachable set.
func (g *Graph) Select(targets []string) (*Selection, error) {
	names := targets
	if len(names) == 0 {
		names = g.plan.Defaults
		if len(names) == 0 {
			return nil, kerr.New(kerr.NoDefault, "")
		}
	}
	seen := make(map[string]struct{}, len(names))
	var roots []int
	for _, t := range names {
		if _, dup := seen[t]; dup {
			continue
		}
		seen[t] = struct{}{}
		n, ok := g.Resolve(t)
		if !ok {
			return nil, kerr.New(kerr.UnknownTarget, "%s", t)
		}
		roots = append(roots, n)
	}
	reach, err := g.findCycle(roots)
	if err != nil {
		return nil, err
	}
	return &Selection{Roots: roots, Reachable: reach}, nil
}

const (
	white = iota
	grey
	black
)

type frame struct{ node, next int }

// findCycle runs the specified depth-first search. On success it returns the
// set of nodes reached.
func (g *Graph) findCycle(roots []int) ([]bool, error) {
	colour := make([]uint8, len(g.Nodes))
	for _, root := range roots {
		if colour[root] != white {
			continue
		}
		colour[root] = grey
		stack := []frame{{root, 0}}
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			succ := g.Nodes[top.node].Succ
			if top.next < len(succ) {
				m := succ[top.next]
				top.next++
				switch colour[m] {
				case grey:
					j := 0
					for stack[j].node != m {
						j++
					}
					names := make([]string, 0, len(stack)-j+1)
					for _, f := range stack[j:] {
						names = append(names, g.Nodes[f.node].Name)
					}
					names = append(names, g.Nodes[m].Name)
					return nil, kerr.New(kerr.Cycle, "%s", strings.Join(names, " -> "))
				case white:
					colour[m] = grey
					stack = append(stack, frame{m, 0})
				}
			} else {
				colour[top.node] = black
				stack = stack[:len(stack)-1]
			}
		}
	}
	reach := make([]bool, len(g.Nodes))
	for i, c := range colour {
		reach[i] = c != white
	}
	return reach, nil
}
