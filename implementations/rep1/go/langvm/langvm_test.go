package langvm_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"langvm"
)

// runText compiles and runs src and renders the result exactly as the
// command-line tool does.
func runText(src string) string {
	var out bytes.Buffer
	if err := langvm.Run([]byte(src), &out); err != nil {
		out.WriteString(err.Error())
		out.WriteByte('\n')
	}
	return out.String()
}

func normalize(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// TestGolden runs every testdata/NAME.in program and compares its output with
// testdata/NAME.out.
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("testdata/*.in")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden tests found: %v", err)
	}
	for _, in := range files {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			if got := runText(string(src)); normalize(got) != normalize(string(want)) {
				t.Errorf("output mismatch\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

func TestCompileDiagnostic(t *testing.T) {
	_, d := langvm.Compile([]byte("@module main\nfn main() {\n    let n: Int = 1;\n    print(n + \"x\");\n}\n"))
	if d == nil {
		t.Fatal("expected a diagnostic")
	}
	if got, want := d.Error(), "error: type-mismatch at 3:15"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestRunPanic(t *testing.T) {
	p, d := langvm.Compile([]byte("@module main\nfn main() { emit(\"a\"); panic(\"boom\"); }\n"))
	if d != nil {
		t.Fatal(d)
	}
	var out bytes.Buffer
	err := p.Run(&out)
	pe, ok := err.(*langvm.Panic)
	if !ok || pe.Msg != "boom" {
		t.Fatalf("expected panic boom, got %v", err)
	}
	if out.String() != "a" {
		t.Errorf("output before panic: %q", out.String())
	}
}

func TestEvaluationBasics(t *testing.T) {
	cases := []struct{ name, body, want string }{
		{"int wrap", `print(showInt(intMax() + 1));`, "-9223372036854775808\n"},
		{"trunc div", `print(showInt(-7 / 2) ++ showInt(-7 % 2));`, "-3-1\n"},
		{"float print", `print(showFloat(2.0 / 3.0));`, "0.666667\n"},
		{"unicode strings", `print(showInt(strLen("héllo")));`, "5\n"},
		{"map order", `var m = #[1: 1]; m[0] = 2; mapDel(m, 1); m[1] = 3; print(showInt(listFirst(keysOf(m))));`, "0\n"},
		{"closure capture by value", `var x = 1; let f = || x; x = 2; print(showInt(f()));`, "1\n"},
		{"sort stable", `print(strJoin(listMap(sortBy([3, 1, 2], |a, b| cmpI(a, b)), |v| showInt(v)), ","));`, "1,2,3\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := runText("@module main\nfn main() {\n" + c.body + "\n}\n")
			if got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestDeepRecursionIsNotHostRecursion(t *testing.T) {
	src := "@module main\nfn d(n: Int) -> Int { if n == 0 { 0 } else { 1 + d(n - 1) } }\n" +
		"fn main() { print(showInt(d(19998))); print(showInt(d(19999))); }\n"
	want := "19998\npanic: call stack overflow\n"
	if got := runText(src); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func ExampleRun() {
	src := `@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}
`
	if err := langvm.Run([]byte(src), os.Stdout); err != nil {
		panic(err)
	}
	// Output: hello, world
}
