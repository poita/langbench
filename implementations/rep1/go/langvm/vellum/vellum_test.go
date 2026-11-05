package vellum_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"langvm/diag"
	"langvm/vellum"
)

func norm(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// TestSpecExamples runs the worked examples of SPEC section 17.
func TestSpecExamples(t *testing.T) {
	files, _ := filepath.Glob("testdata/*.in")
	if len(files) == 0 {
		t.Fatal("no testdata")
	}
	for _, f := range files {
		in, _ := os.ReadFile(f)
		want, _ := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
		got := vellum.Run(in)
		if norm(string(got)) != norm(string(want)) {
			t.Errorf("%s:\n got: %q\nwant: %q", f, got, want)
		}
	}
}

// TestProblemSuite runs the problem's test suite when it sits next to the
// project (the repository layout used for development).
func TestProblemSuite(t *testing.T) {
	files, _ := filepath.Glob("../../problems/langvm/tests/*.in")
	if len(files) == 0 {
		t.Skip("problem test suite not found")
	}
	for _, f := range files {
		in, _ := os.ReadFile(f)
		want, _ := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
		if got := vellum.Run(in); norm(string(got)) != norm(string(want)) {
			t.Errorf("%s:\n got: %q\nwant: %q", filepath.Base(f), got, want)
		}
	}
}

func TestSplitModules(t *testing.T) {
	mods, err := vellum.SplitModules([]byte("@module a\nx\r\ny\n@module b\n@module c\nz"))
	if err != nil {
		t.Fatal(err)
	}
	if len(mods) != 3 || mods[0].Name != "a" || string(mods[0].Body) != "x\ny" ||
		string(mods[1].Body) != "" || string(mods[2].Body) != "z" {
		t.Fatalf("unexpected split: %+v", mods)
	}
	cases := []struct {
		src  string
		kind diag.Kind
		line int
	}{
		{"", diag.BadModule, 1},
		{"fn main() {}", diag.BadModule, 1},
		{"@module main\n@module  x", diag.BadModule, 2},
		{"@module main\nx\n@module x \n", diag.BadModule, 3},
		{"@module main\n@module fn", diag.BadModule, 2},
		{"@module main\n@module _", diag.BadModule, 2},
		{"@module main\n@oops", diag.BadModule, 2},
		{"@module a\n@module b\n@module a", diag.DupModule, 3},
		{"@module " + strings.Repeat("a", 201), diag.BadModule, 1},
	}
	for _, c := range cases {
		_, err := vellum.SplitModules([]byte(c.src))
		if err == nil || err.Kind != c.kind || err.Pos.Line != c.line || err.Pos.Col != 1 {
			t.Errorf("%q: got %v, want %s at %d:1", c.src, err, c.kind, c.line)
		}
	}
}

func TestRunOutputs(t *testing.T) {
	cases := []struct{ name, src, want string }{
		{"emit then panic continues the line",
			"@module main\nfn main() { emit(\"a\"); panic(\"boom\"); }", "apanic: boom\n"},
		{"panic stops execution",
			"@module main\nfn main() { print(\"x\"); let xs = [1]; print(showInt(xs[1])); print(\"y\"); }",
			"x\npanic: index out of bounds\n"},
		{"diagnostic replaces all output",
			"@module main\nfn main() { print(\"x\"); let y: Int = \"s\"; }", "error: type-mismatch at 1:38\n"},
		{"closures capture by value",
			"@module main\nfn main() { var a = 1; let f = || a; a = 2; print(showInt(f())); }", "1\n"},
		{"struct literal evaluates in written order",
			"@module main\nstruct P { a: Int, b: Int }\nfn t(s: Str, n: Int) -> Int { emit(s); n }\nfn main() { let p = P.{ b: t(\"b\", 2), a: t(\"a\", 1) }; print(showInt(p.a * 10 + p.b)); }",
			"ba12\n"},
		{"for sees a growing list",
			"@module main\nfn main() { let xs = [1]; var n = 0; for x in xs { if x < 4 { push(xs, x + 1); } n = n + 1; } print(showInt(n)); }", "4\n"},
		{"deep recursion",
			"@module main\nfn d(n: Int) -> Int { if n == 0 { 0 } else { 1 + d(n - 1) } }\nfn main() { print(showInt(d(15000))); }", "15000\n"},
	}
	for _, c := range cases {
		if got := string(vellum.Run([]byte(c.src))); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
