package graph

import (
	"testing"

	"buildsys/cmds"
	"buildsys/plan"
	"buildsys/vfs"
)

type step struct {
	out string
	ins []string
	aft []string
	dep string
}

func mk(steps []step, phonies map[string][]string, order []string, defaults ...string) *plan.Build {
	b := plan.NewBuild()
	for _, s := range steps {
		name := "write"
		var args []cmds.Arg
		if len(s.ins) > 0 {
			name = "concat"
		} else {
			args = []cmds.Arg{{Str: "x"}}
		}
		d := &plan.Draft{Outs: []string{s.out}, Ins: s.ins, Afters: s.aft, Cmd: &cmds.Command{Spec: cmds.Lookup(name), Args: args}}
		if s.dep != "" {
			d.Depfile, d.HasDepfile = s.dep, true
			d.Cmd = &cmds.Command{Spec: cmds.Lookup("preprocess")}
		}
		st, err := d.Finish()
		if err != nil {
			panic(err)
		}
		b.AddStep(st)
	}
	for _, n := range order {
		b.AddPhony(n, phonies[n])
	}
	b.AddDefault(defaults...)
	return b
}

func files(paths ...string) *vfs.FS {
	f := vfs.New()
	for _, p := range paths {
		f.Write(p, nil)
	}
	return f
}

func TestValidationErrors(t *testing.T) {
	cases := []struct {
		name string
		b    *plan.Build
		fs   *vfs.FS
		want string
	}{
		{"dup", mk([]step{{out: "out/a"}, {out: "out/a"}}, nil, nil), files(), "E_DUP_OUTPUT out/a"},
		{"dup depfile", mk([]step{{out: "out/a"}, {out: "out/b", dep: "out/a", ins: []string{"src/x"}}}, nil, nil), files("src/x"), "E_DUP_OUTPUT out/a"},
		{"missing", mk([]step{{out: "out/a", ins: []string{"src/x"}}}, nil, nil), files(), "E_MISSING_INPUT src/x required by out/a"},
		{"missing after", mk([]step{{out: "out/a", aft: []string{"@p"}}}, nil, nil), files(), "E_MISSING_INPUT @p required by out/a"},
		{"missing phony dep", mk(nil, map[string][]string{"p": {"zzz"}}, []string{"p"}), files(), "E_MISSING_INPUT zzz required by @p"},
		{"bad default", mk([]step{{out: "out/a"}}, nil, nil, "nope"), files(), "E_UNKNOWN_TARGET nope"},
	}
	for _, c := range cases {
		_, err := New(c.b, c.fs)
		if err == nil || err.Error() != c.want {
			t.Errorf("%s: got %v, want %s", c.name, err, c.want)
		}
	}
}

func TestStepsResolveBeforePhonies(t *testing.T) {
	b := mk([]step{{out: "out/a", ins: []string{"src/missing"}}}, map[string][]string{"p": {"nope"}}, []string{"p"})
	if _, err := New(b, files()); err == nil || err.Error() != "E_MISSING_INPUT src/missing required by out/a" {
		t.Errorf("got %v", err)
	}
}

func TestRequestedAndReach(t *testing.T) {
	b := mk([]step{
		{out: "out/a", ins: []string{"src/x"}},
		{out: "out/b", ins: []string{"out/a", "src/x"}, aft: []string{"@p"}},
		{out: "out/unused", ins: []string{"src/y"}},
	}, map[string][]string{"p": {"src/x"}}, []string{"p"}, "out/b", "out/b")
	g, err := New(b, files("src/x", "src/y"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := g.Requested([]string{"out/zzz"}); err == nil || err.Error() != "E_UNKNOWN_TARGET out/zzz" {
		t.Errorf("got %v", err)
	}
	roots, err := g.Requested(nil)
	if err != nil || len(roots) != 1 {
		t.Fatalf("roots %v %v", roots, err)
	}
	reach, err := g.Reach(roots)
	if err != nil {
		t.Fatal(err)
	}
	if !reach[0] || !reach[1] || reach[2] || !reach[3] {
		t.Errorf("reach %v", reach)
	}
	if g.NodeKind(0) != StepNode || g.NodeKind(3) != PhonyNode || g.NodeKind(4) != SourceNode {
		t.Error("kinds")
	}
	if g.Name(3) != "@p" || g.Name(4) != "src/x" {
		t.Errorf("names %q %q", g.Name(3), g.Name(4))
	}
	if succ := g.Successors(1); len(succ) != 3 {
		t.Errorf("successors %v", succ)
	}
	// Requesting a source path directly works.
	roots, err = g.Requested([]string{"src/y"})
	if err != nil || g.NodeKind(roots[0]) != SourceNode {
		t.Errorf("source root: %v %v", roots, err)
	}
}

func TestNoDefault(t *testing.T) {
	g, _ := New(mk([]step{{out: "out/a"}}, nil, nil), files())
	if _, err := g.Requested(nil); err == nil || err.Error() != "E_NO_DEFAULT" {
		t.Errorf("got %v", err)
	}
}

func TestCycles(t *testing.T) {
	b := mk([]step{
		{out: "out/x", ins: []string{"out/y"}},
		{out: "out/y", ins: []string{"out/x"}},
		{out: "out/self", ins: []string{"out/self"}},
		{out: "out/a", ins: []string{"out/b"}},
		{out: "out/b", ins: []string{"out/c"}},
		{out: "out/c", ins: []string{"out/b"}},
	}, nil, nil)
	g, err := New(b, files())
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"out/x":    "E_CYCLE out/x -> out/y -> out/x",
		"out/self": "E_CYCLE out/self -> out/self",
		"out/a":    "E_CYCLE out/b -> out/c -> out/b",
	}
	for target, want := range cases {
		roots, _ := g.Requested([]string{target})
		if _, err := g.Reach(roots); err == nil || err.Error() != want {
			t.Errorf("%s: got %v, want %s", target, err, want)
		}
	}
}

func TestDiamondIsNotACycle(t *testing.T) {
	b := mk([]step{
		{out: "out/top", ins: []string{"out/l", "out/r"}},
		{out: "out/l", ins: []string{"out/base"}},
		{out: "out/r", ins: []string{"out/base"}},
		{out: "out/base"},
	}, nil, nil)
	g, _ := New(b, files())
	roots, _ := g.Requested([]string{"out/top"})
	reach, err := g.Reach(roots)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		if !reach[i] {
			t.Errorf("node %d unreachable", i)
		}
	}
}
