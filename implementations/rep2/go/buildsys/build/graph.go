package build

import (
	"strings"

	"kiln/errs"
	"kiln/kbl"
	"kiln/vfs"
)

type nodeKind uint8

const (
	nStep nodeKind = iota
	nPhony
	nSource
)

type node struct {
	kind  nodeKind
	step  *kbl.Step
	phony *kbl.Phony
	path  string // source path
	succ  []int  // ordering dependencies, duplicates removed
}

// graph is the dependency graph of one build. Step nodes come first, so a
// step's node index equals its serial number.
type graph struct {
	prog     *kbl.Program
	fs       *vfs.FS
	nodes    []node
	outOwner map[string]int // output path -> step node
	phonyIdx map[string]int // phony name -> node
	srcIdx   map[string]int // source path -> node
}

func (g *graph) name(n int) string {
	nd := &g.nodes[n]
	switch nd.kind {
	case nStep:
		return nd.step.Primary()
	case nPhony:
		return "@" + nd.phony.Name
	}
	return nd.path
}

// resolve maps a target reference to a node.
func (g *graph) resolve(ref string) (int, bool) {
	if strings.HasPrefix(ref, "@") {
		n, ok := g.phonyIdx[ref[1:]]
		return n, ok
	}
	if n, ok := g.outOwner[ref]; ok {
		return n, true
	}
	if n, ok := g.srcIdx[ref]; ok {
		return n, true
	}
	if g.fs.Exists(ref) {
		g.nodes = append(g.nodes, node{kind: nSource, path: ref})
		n := len(g.nodes) - 1
		g.srcIdx[ref] = n
		return n, true
	}
	return 0, false
}

func dedup(l []int) []int {
	if len(l) < 2 {
		return l
	}
	seen := make(map[int]struct{}, len(l))
	out := make([]int, 0, len(l))
	for _, n := range l {
		if _, dup := seen[n]; !dup {
			seen[n] = struct{}{}
			out = append(out, n)
		}
	}
	return out
}

// newGraph performs whole-graph validation: duplicate outputs, reference
// resolution, then the default list.
func newGraph(prog *kbl.Program, fs *vfs.FS) (*graph, *errs.Error) {
	g := &graph{
		prog:     prog,
		fs:       fs,
		outOwner: map[string]int{},
		phonyIdx: map[string]int{},
		srcIdx:   map[string]int{},
	}
	for _, s := range prog.Steps {
		g.nodes = append(g.nodes, node{kind: nStep, step: s})
	}
	for _, p := range prog.Phonies {
		g.nodes = append(g.nodes, node{kind: nPhony, phony: p})
		g.phonyIdx[p.Name] = len(g.nodes) - 1
	}
	for i, s := range prog.Steps {
		for _, o := range s.FullOutputs() {
			if _, dup := g.outOwner[o]; dup {
				return nil, errs.New(errs.DupOutput, "%s", o)
			}
			g.outOwner[o] = i
		}
	}
	for i, s := range prog.Steps {
		deps := make([]int, 0, len(s.Ins)+len(s.After))
		for _, list := range [][]string{s.Ins, s.After} {
			for _, ref := range list {
				n, ok := g.resolve(ref)
				if !ok {
					return nil, errs.New(errs.MissingInput, "%s required by %s", ref, s.Primary())
				}
				deps = append(deps, n)
			}
		}
		g.nodes[i].succ = dedup(deps)
	}
	for _, p := range prog.Phonies {
		idx := g.phonyIdx[p.Name]
		deps := make([]int, 0, len(p.Deps))
		for _, ref := range p.Deps {
			n, ok := g.resolve(ref)
			if !ok {
				return nil, errs.New(errs.MissingInput, "%s required by @%s", ref, p.Name)
			}
			deps = append(deps, n)
		}
		g.nodes[idx].succ = dedup(deps)
	}
	for _, ref := range prog.Defaults {
		if _, ok := g.resolve(ref); !ok {
			return nil, errs.New(errs.UnknownTarget, "%s", ref)
		}
	}
	return g, nil
}

// requested resolves the requested targets: the explicit ones, or the
// default list when none were given.
func (g *graph) requested(targets []string) ([]int, *errs.Error) {
	list := targets
	if len(list) == 0 {
		list = g.prog.Defaults
	}
	if len(list) == 0 {
		return nil, errs.Bare(errs.NoDefault)
	}
	seen := map[string]bool{}
	var roots []int
	for _, t := range list {
		if seen[t] {
			continue
		}
		seen[t] = true
		n, ok := g.resolve(t)
		if !ok {
			return nil, errs.New(errs.UnknownTarget, "%s", t)
		}
		roots = append(roots, n)
	}
	return roots, nil
}

// reach runs the specified deterministic depth-first search from the roots.
// It returns the reachable set, or an E_CYCLE error.
func (g *graph) reach(roots []int) ([]bool, *errs.Error) {
	const (
		white = iota
		grey
		black
	)
	colour := make([]uint8, len(g.nodes))
	type frame struct{ n, i int }
	for _, root := range roots {
		if colour[root] != white {
			continue
		}
		colour[root] = grey
		stack := []frame{{root, 0}}
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			succ := g.nodes[top.n].succ
			if top.i < len(succ) {
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
						names = append(names, g.name(f.n))
					}
					names = append(names, g.name(m))
					return nil, errs.New(errs.Cycle, "%s", strings.Join(names, " -> "))
				case white:
					colour[m] = grey
					stack = append(stack, frame{m, 0})
				}
			} else {
				colour[top.n] = black
				stack = stack[:len(stack)-1]
			}
		}
	}
	reach := make([]bool, len(g.nodes))
	for i, c := range colour {
		reach[i] = c != white
	}
	return reach, nil
}
