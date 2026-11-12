package graph_test

import (
	"testing"

	"buildsys/cmds"
	"buildsys/graph"
	"buildsys/vfs"
)

func step(serial int, out string, in, after []string) *graph.Step {
	spec, _ := cmds.Lookup("concat")
	s := &graph.Step{Serial: serial, Outputs: []string{out}, Inputs: in, After: after,
		Cmd: cmds.Invocation{Name: "concat"}, Spec: spec, Cost: 1}
	s.Finish()
	return s
}

func TestResolutionAndValidation(t *testing.T) {
	fs := vfs.New()
	fs.Write("src/a", "a")
	steps := []*graph.Step{
		step(0, "out/x", []string{"src/a"}, nil),
		step(1, "out/y", []string{"out/x", "@p"}, []string{"src/a"}),
	}
	phonies := []graph.Phony{{Name: "p", Deps: []string{"out/x"}}}
	g, err := graph.New(fs, steps, phonies)
	if err != nil {
		t.Fatal(err)
	}
	if n, ok := g.Resolve("out/y"); !ok || g.Nodes[n].Kind != graph.StepNode || g.Nodes[n].Name != "out/y" {
		t.Errorf("out/y resolved to %v %v", n, ok)
	}
	if n, ok := g.Resolve("src/a"); !ok || g.Nodes[n].Kind != graph.SourceNode {
		t.Errorf("src/a resolved to %v %v", n, ok)
	}
	if n, ok := g.Resolve("@p"); !ok || g.Nodes[n].Name != "@p" {
		t.Errorf("@p resolved to %v %v", n, ok)
	}
	if _, ok := g.Resolve("@q"); ok {
		t.Error("@q should not resolve")
	}
	if _, ok := g.Resolve("src/none"); ok {
		t.Error("src/none should not resolve")
	}
	// Successors are deduplicated, inputs first then after.
	if succ := g.Nodes[1].Succ; len(succ) != 3 {
		t.Errorf("succ = %v", succ)
	}
	if err := g.ResolveDefaults([]string{"out/y", "nope"}); err == nil || err.Error() != "E_UNKNOWN_TARGET nope" {
		t.Errorf("defaults: %v", err)
	}

	_, err = graph.New(fs, []*graph.Step{step(0, "out/x", nil, nil), step(1, "out/x", nil, nil)}, nil)
	if err == nil || err.Error() != "E_DUP_OUTPUT out/x" {
		t.Errorf("dup: %v", err)
	}
	_, err = graph.New(fs, []*graph.Step{step(0, "out/x", []string{"src/missing"}, nil)}, nil)
	if err == nil || err.Error() != "E_MISSING_INPUT src/missing required by out/x" {
		t.Errorf("missing: %v", err)
	}
	_, err = graph.New(fs, nil, []graph.Phony{{Name: "p", Deps: []string{"@q"}}})
	if err == nil || err.Error() != "E_MISSING_INPUT @q required by @p" {
		t.Errorf("phony missing: %v", err)
	}
}

func TestCycleDetection(t *testing.T) {
	fs := vfs.New()
	steps := []*graph.Step{
		step(0, "out/a", []string{"out/b"}, nil),
		step(1, "out/b", []string{"out/c"}, nil),
		step(2, "out/c", []string{"out/a"}, nil),
		step(3, "out/self", []string{"out/self"}, nil),
		step(4, "out/free", nil, nil),
	}
	g, err := graph.New(fs, steps, nil)
	if err != nil {
		t.Fatal(err)
	}
	root := func(p string) []int { r, _ := g.Resolve(p); return []int{r} }

	if _, err := g.Reachable(root("out/b")); err == nil || err.Error() != "E_CYCLE out/b -> out/c -> out/a -> out/b" {
		t.Errorf("cycle: %v", err)
	}
	if _, err := g.Reachable(root("out/self")); err == nil || err.Error() != "E_CYCLE out/self -> out/self" {
		t.Errorf("self cycle: %v", err)
	}
	reach, err := g.Reachable(root("out/free"))
	if err != nil {
		t.Fatal(err)
	}
	if !reach[4] || reach[0] || reach[3] {
		t.Errorf("reach = %v", reach)
	}
}

func TestRequestDedup(t *testing.T) {
	fs := vfs.New()
	g, _ := graph.New(fs, []*graph.Step{step(0, "out/a", nil, nil)}, nil)
	roots, err := g.Request([]string{"out/a", "out/a"})
	if err != nil || len(roots) != 1 {
		t.Errorf("roots = %v, %v", roots, err)
	}
	if _, err := g.Request([]string{"-j"}); err == nil || err.Error() != "E_UNKNOWN_TARGET -j" {
		t.Errorf("err = %v", err)
	}
}
