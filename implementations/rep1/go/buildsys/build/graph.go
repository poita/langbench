package build

import (
	"strings"

	"buildsys/kilnerr"
	"buildsys/plan"
	"buildsys/vfs"
)

type nodeKind uint8

const (
	nStep nodeKind = iota
	nPhony
	nSource
)

// graph is the dependency graph of one build. Step nodes occupy ids
// 0..S-1 (their serial numbers), phony nodes follow, then source nodes.
type graph struct {
	fs   *vfs.FS
	plan *plan.Plan

	kind []nodeKind
	name []string
	succ [][]int32 // deduplicated ordering dependencies

	outStep   map[string]int // output path -> step serial
	phonyNode map[string]int // phony name -> node id
	srcNode   map[string]int // source path -> node id
	seen      []int32        // per-node stamp for successor de-duplication
	stamp     int32
}

// resolve maps a target reference to a node, creating source nodes on demand.
func (g *graph) resolve(ref string) (int, bool) {
	if strings.HasPrefix(ref, "@") {
		n, ok := g.phonyNode[ref[1:]]
		return n, ok
	}
	if s, ok := g.outStep[ref]; ok {
		return s, true
	}
	if n, ok := g.srcNode[ref]; ok {
		return n, true
	}
	if g.fs.Exists(ref) {
		n := g.addNode(nSource, ref)
		g.srcNode[ref] = n
		return n, true
	}
	return 0, false
}

func (g *graph) addNode(k nodeKind, name string) int {
	g.kind = append(g.kind, k)
	g.name = append(g.name, name)
	g.succ = append(g.succ, nil)
	return len(g.kind) - 1
}

// buildGraph performs whole-graph validation (duplicate outputs, reference
// resolution) and constructs successor lists.
func buildGraph(fs *vfs.FS, p *plan.Plan) (*graph, *kilnerr.Error) {
	g := &graph{
		fs:        fs,
		plan:      p,
		outStep:   make(map[string]int, len(p.Steps)),
		phonyNode: make(map[string]int, len(p.Phonies)),
		srcNode:   map[string]int{},
	}
	for _, s := range p.Steps {
		g.addNode(nStep, s.Primary())
	}
	for _, ph := range p.Phonies {
		g.phonyNode[ph.Name] = g.addNode(nPhony, "@"+ph.Name)
	}
	// 1. Duplicate outputs.
	for _, s := range p.Steps {
		for _, o := range s.FullOuts {
			if _, dup := g.outStep[o]; dup {
				return nil, kilnerr.New(kilnerr.DupOutput, o)
			}
			g.outStep[o] = s.Serial
		}
	}
	// 2. Reference resolution, in serial order then phony declaration order.
	var buf []int32
	for _, s := range p.Steps {
		buf = buf[:0]
		for _, list := range [2][]string{s.Ins, s.After} {
			for _, ref := range list {
				n, ok := g.resolve(ref)
				if !ok {
					return nil, kilnerr.New(kilnerr.MissingInput, ref+" required by "+g.name[s.Serial])
				}
				buf = append(buf, int32(n))
			}
		}
		g.succ[s.Serial] = g.dedupe(buf)
	}
	for _, ph := range p.Phonies {
		id := g.phonyNode[ph.Name]
		buf = buf[:0]
		for _, ref := range ph.Deps {
			n, ok := g.resolve(ref)
			if !ok {
				return nil, kilnerr.New(kilnerr.MissingInput, ref+" required by "+g.name[id])
			}
			buf = append(buf, int32(n))
		}
		g.succ[id] = g.dedupe(buf)
	}
	// 3. Default list.
	for _, ref := range p.Defaults {
		if _, ok := g.resolve(ref); !ok {
			return nil, kilnerr.New(kilnerr.UnknownTarget, ref)
		}
	}
	return g, nil
}

// dedupe returns a fresh copy of ids with repeats removed, keeping the first
// occurrence of each.
func (g *graph) dedupe(ids []int32) []int32 {
	if len(ids) == 0 {
		return nil
	}
	for len(g.seen) < len(g.kind) {
		g.seen = append(g.seen, 0)
	}
	g.stamp++
	out := make([]int32, 0, len(ids))
	for _, id := range ids {
		if g.seen[id] != g.stamp {
			g.seen[id] = g.stamp
			out = append(out, id)
		}
	}
	return out
}

// requested resolves the requested targets of a build.
func (g *graph) requested(targets []string) ([]int, *kilnerr.Error) {
	list := targets
	if len(list) == 0 {
		list = g.plan.Defaults
		if len(list) == 0 {
			return nil, kilnerr.New(kilnerr.NoDefault, "")
		}
	}
	seen := make(map[string]bool, len(list))
	var roots []int
	for _, t := range list {
		if seen[t] {
			continue
		}
		seen[t] = true
		n, ok := g.resolve(t)
		if !ok {
			return nil, kilnerr.New(kilnerr.UnknownTarget, t)
		}
		roots = append(roots, n)
	}
	return roots, nil
}

type colour uint8

const (
	white colour = iota
	grey
	black
)

type frame struct {
	node int32
	next int
}

// reach runs the spec's iterative depth-first search from the roots. It
// returns either a cycle error or the colouring in which every non-white
// node is reachable.
func (g *graph) reach(roots []int) ([]colour, *kilnerr.Error) {
	col := make([]colour, len(g.kind))
	for _, root := range roots {
		if col[root] != white {
			continue
		}
		col[root] = grey
		stack := []frame{{int32(root), 0}}
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			succ := g.succ[top.node]
			if top.next < len(succ) {
				m := succ[top.next]
				top.next++
				switch col[m] {
				case grey:
					j := 0
					for stack[j].node != m {
						j++
					}
					names := make([]string, 0, len(stack)-j+1)
					for _, f := range stack[j:] {
						names = append(names, g.name[f.node])
					}
					names = append(names, g.name[m])
					return nil, kilnerr.New(kilnerr.Cycle, strings.Join(names, " -> "))
				case white:
					col[m] = grey
					stack = append(stack, frame{m, 0})
				}
			} else {
				col[top.node] = black
				stack = stack[:len(stack)-1]
			}
		}
	}
	return col, nil
}
