package graph_test

import (
	"testing"

	"buildsys/graph"
	"buildsys/kbl"
	"buildsys/vfs"
)

func build(t *testing.T, files map[string]string, targets ...string) (*graph.Selection, error) {
	t.Helper()
	fs := vfs.New()
	for p, c := range files {
		fs.Write(p, c)
	}
	p, err := kbl.Evaluate(fs, "main.kiln")
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	g, err := graph.New(p, fs)
	if err != nil {
		return nil, err
	}
	return g.Select(targets)
}

const stepA = "step {\n out \"out/a\"\n in \"%s\"\n cmd copy()\n}\n"

func TestErrors(t *testing.T) {
	step := func(out string, in ...string) string {
		s := "step {\n out \"" + out + "\"\n"
		for _, i := range in {
			s += " in \"" + i + "\"\n"
		}
		return s + " cmd concat()\n}\n"
	}
	tests := []struct {
		name  string
		main  string
		files map[string]string
		args  []string
		want  string
	}{
		{"dup output", step("out/a", "main.kiln") + step("out/a", "main.kiln"), nil, nil, "E_DUP_OUTPUT out/a"},
		{"missing input", step("out/a", "nope"), nil, nil, "E_MISSING_INPUT nope required by out/a"},
		{"missing phony dep", "phony p = \"@q\"\n", nil, nil, "E_MISSING_INPUT @q required by @p"},
		{"unknown default", "default \"zzz\"\n", nil, nil, "E_UNKNOWN_TARGET zzz"},
		{"no default", step("out/a", "main.kiln"), nil, nil, "E_NO_DEFAULT"},
		{"unknown requested", step("out/a", "main.kiln"), nil, []string{"@x"}, "E_UNKNOWN_TARGET @x"},
		{"self cycle", step("out/a", "out/a"), nil, []string{"out/a"}, "E_CYCLE out/a -> out/a"},
		{"two cycle", step("out/x", "out/y") + step("out/y", "out/x"), nil, []string{"out/x"}, "E_CYCLE out/x -> out/y -> out/x"},
		{"cycle via phony", step("out/x", "@p", "main.kiln") + "phony p = \"out/x\"\n", nil, []string{"@p"}, "E_CYCLE @p -> out/x -> @p"},
	}
	for _, tc := range tests {
		files := map[string]string{"main.kiln": tc.main}
		for k, v := range tc.files {
			files[k] = v
		}
		_, err := build(t, files, tc.args...)
		if err == nil || err.Error() != tc.want {
			t.Errorf("%s: got %v, want %s", tc.name, err, tc.want)
		}
	}
}

func TestUnreachableCycleIgnored(t *testing.T) {
	main := "step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\n" +
		"step {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\n" +
		"step {\n out \"out/ok\"\n in \"main.kiln\"\n cmd copy()\n}\n"
	sel, err := build(t, map[string]string{"main.kiln": main}, "out/ok")
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range sel.Reachable {
		if r {
			n++
		}
	}
	if n != 2 { // the step and its source main.kiln
		t.Errorf("reachable = %d, want 2", n)
	}
}

func TestRootsDeduplicated(t *testing.T) {
	main := "step {\n out \"out/a\"\n in \"main.kiln\"\n cmd copy()\n}\n"
	sel, err := build(t, map[string]string{"main.kiln": main}, "out/a", "out/a", "main.kiln")
	if err != nil {
		t.Fatal(err)
	}
	if len(sel.Roots) != 2 {
		t.Errorf("roots = %v", sel.Roots)
	}
}
