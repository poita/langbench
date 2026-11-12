// Package graph builds and validates the dependency graph of a Kiln build: the
// build steps, phony targets and source files, the references between them,
// and the depth-first cycle search that also yields the reachable set.
package graph

import (
	"strings"

	"buildsys/cmds"
	"buildsys/kerr"
	"buildsys/vfs"
)

// Step is one build step produced by evaluating a `step` block.
type Step struct {
	// Serial is the step's creation order (0, 1, 2, ...).
	Serial int
	// Outputs are the declared outputs, in order. The first is the primary
	// output.
	Outputs []string
	// Inputs are the declared inputs, including phony references.
	Inputs []string
	// After are the order-only dependencies.
	After []string
	// Depfile is the depfile path; valid only if HasDepfile.
	Depfile    string
	HasDepfile bool
	// Cost is the step's cost in simulated time units.
	Cost int64
	// Cmd is the step's command invocation.
	Cmd cmds.Invocation
	// Spec is the static description of Cmd.
	Spec *cmds.Spec

	// FileInputs are the declared inputs that are not phony references, in
	// declaration order (duplicates kept).
	FileInputs []string
	// FullOutputs are the declared outputs followed by the depfile.
	FullOutputs []string
	canonical   string
}

// Finish computes the derived fields. It must be called once the declared
// fields are final.
func (s *Step) Finish() {
	s.FileInputs = s.FileInputs[:0]
	for _, in := range s.Inputs {
		if !strings.HasPrefix(in, "@") {
			s.FileInputs = append(s.FileInputs, in)
		}
	}
	s.FullOutputs = append([]string(nil), s.Outputs...)
	if s.HasDepfile {
		s.FullOutputs = append(s.FullOutputs, s.Depfile)
	}
	s.canonical = s.Cmd.String()
}

// Primary returns the step's primary output path.
func (s *Step) Primary() string { return s.Outputs[0] }

// Canonical returns the canonical command string.
func (s *Step) Canonical() string { return s.canonical }

// Phony is a phony target: a named, ordering-only group of dependencies.
type Phony struct {
	Name string
	Deps []string
}

// NodeKind tells what a graph node stands for.
type NodeKind uint8

// Node kinds.
const (
	StepNode NodeKind = iota
	PhonyNode
	SourceNode
)

// Node is a vertex of the dependency graph.
type Node struct {
	Kind NodeKind
	// Name is the name used in messages: the primary output, "@name" or a path.
	Name string
	// Step is set for step nodes.
	Step *Step
	// Succ are the node's ordering dependencies, deduplicated, first
	// occurrence kept.
	Succ []int
}

// Graph is the dependency graph of one build.
type Graph struct {
	// Nodes holds step nodes first (index == serial), then phony nodes in
	// declaration order, then source nodes in order of first reference.
	Nodes []Node

	fs      *vfs.FS
	steps   []*Step
	phonies []Phony
	outputs map[string]int // output path -> step serial
	phony   map[string]int // phony name -> node index
	source  map[string]int // source path -> node index
}

// New builds the graph and performs whole-graph validation: duplicate outputs,
// then reference resolution for every step and phony target.
func New(fs *vfs.FS, steps []*Step, phonies []Phony) (*Graph, *kerr.Error) {
	g := &Graph{
		fs: fs, steps: steps, phonies: phonies,
		outputs: map[string]int{}, phony: map[string]int{}, source: map[string]int{},
	}
	for _, s := range steps {
		for _, o := range s.FullOutputs {
			if _, dup := g.outputs[o]; dup {
				return nil, kerr.New(kerr.DupOutput, "%s", o)
			}
			g.outputs[o] = s.Serial
		}
		g.Nodes = append(g.Nodes, Node{Kind: StepNode, Name: s.Primary(), Step: s})
	}
	for i, p := range phonies {
		g.phony[p.Name] = len(g.Nodes)
		g.Nodes = append(g.Nodes, Node{Kind: PhonyNode, Name: "@" + p.Name})
		_ = i
	}
	for _, s := range steps {
		var succ []int
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
	for i, p := range phonies {
		var succ []int
		for _, ref := range p.Deps {
			n, ok := g.Resolve(ref)
			if !ok {
				return nil, kerr.New(kerr.MissingInput, "%s required by @%s", ref, p.Name)
			}
			succ = append(succ, n)
		}
		g.Nodes[len(steps)+i].Succ = dedup(succ)
	}
	return g, nil
}

func dedup(xs []int) []int {
	if len(xs) < 2 {
		return xs
	}
	seen := make(map[int]struct{}, len(xs))
	out := xs[:0]
	for _, x := range xs {
		if _, ok := seen[x]; ok {
			continue
		}
		seen[x] = struct{}{}
		out = append(out, x)
	}
	return out
}

// Resolve resolves a target reference to a node: a phony ("@name"), the step
// whose full output list contains the path, or an existing source file.
func (g *Graph) Resolve(ref string) (int, bool) {
	if strings.HasPrefix(ref, "@") {
		n, ok := g.phony[ref[1:]]
		return n, ok
	}
	if serial, ok := g.outputs[ref]; ok {
		return serial, true
	}
	if n, ok := g.source[ref]; ok {
		return n, true
	}
	if g.fs.Exists(ref) {
		n := len(g.Nodes)
		g.Nodes = append(g.Nodes, Node{Kind: SourceNode, Name: ref})
		g.source[ref] = n
		return n, true
	}
	return 0, false
}

// ResolveDefaults checks that every default target resolves.
func (g *Graph) ResolveDefaults(defaults []string) *kerr.Error {
	for _, d := range defaults {
		if _, ok := g.Resolve(d); !ok {
			return kerr.New(kerr.UnknownTarget, "%s", d)
		}
	}
	return nil
}

// Request resolves the requested targets, after removing duplicates. An empty
// list is E_NO_DEFAULT.
func (g *Graph) Request(targets []string) ([]int, *kerr.Error) {
	var seen = map[string]bool{}
	var roots []int
	for _, t := range targets {
		if seen[t] {
			continue
		}
		seen[t] = true
		n, ok := g.Resolve(t)
		if !ok {
			return nil, kerr.New(kerr.UnknownTarget, "%s", t)
		}
		roots = append(roots, n)
	}
	return roots, nil
}

// Reachable runs the deterministic cycle-detecting depth-first search from the
// roots. It returns the reachable set as a boolean slice indexed by node, or
// an E_CYCLE error.
func (g *Graph) Reachable(roots []int) ([]bool, *kerr.Error) {
	const (
		white = iota
		grey
		black
	)
	colour := make([]uint8, len(g.Nodes))
	type frame struct{ n, i int }
	for _, root := range roots {
		if colour[root] != white {
			continue
		}
		colour[root] = grey
		stack := []frame{{root, 0}}
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			succ := g.Nodes[top.n].Succ
			if top.i >= len(succ) {
				colour[top.n] = black
				stack = stack[:len(stack)-1]
				continue
			}
			m := succ[top.i]
			top.i++
			switch colour[m] {
			case grey:
				j := 0
				for stack[j].n != m {
					j++
				}
				names := make([]string, 0, len(stack)-j+1)
				for _, f := range stack[j:] {
					names = append(names, g.Nodes[f.n].Name)
				}
				names = append(names, g.Nodes[m].Name)
				return nil, kerr.New(kerr.Cycle, "%s", strings.Join(names, " -> "))
			case white:
				colour[m] = grey
				stack = append(stack, frame{m, 0})
			}
		}
	}
	reach := make([]bool, len(g.Nodes))
	for i, c := range colour {
		reach[i] = c != white
	}
	return reach, nil
}
