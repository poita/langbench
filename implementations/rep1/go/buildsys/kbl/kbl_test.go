package kbl

import (
	"reflect"
	"testing"

	"buildsys/vfs"
)

func workspace(files map[string]string) *vfs.FS {
	f := vfs.New()
	for p, c := range files {
		f.Write(p, c)
	}
	return f
}

// evalOut evaluates a build file whose last statement is `default <expr>` and
// returns the default list or the error text.
func evalDefault(files map[string]string) ([]string, string) {
	p, err := Evaluate(workspace(files), "main.kiln")
	if err != nil {
		return nil, err.Error()
	}
	return p.Defaults, ""
}

func TestExpressions(t *testing.T) {
	tests := []struct {
		expr, want string
	}{
		{`"{1 + 2 * 3}"`, "7"},
		{`"{-7 / 2} {-7 % 3} {7 % -3}"`, "-3 -1 1"},
		{`"{1 < 2 && 2 < 1 || true}"`, "true"},
		{`"{[1, 2] < [1, 3]} {"a" < 1} {true < 0}"`, "true false true"},
		{`"{"a" ~ "b" ~ "c"}"`, "abc"},
		{`"{len([1] ++ [2, 3])}"`, "3"},
		{`"{"abc"[-1]}{[5, 6][0]}"`, "c5"},
		{`"x" |> upper |> replace("X", "yy")`, "yy"},
		{`"{{lit}} {'a''b'}"`, "{lit} a'b"},
		{`'a\n{x}'`, `a\n{x}`},
		{`"\t\\\"\0" |> len |> str`, "4"},
		{`"{false && (1 / 0 == 1)}{true || undefined}"`, "falsetrue"},
		{`"{join(split("a,,b", ","), "|")}"`, "a||b"},
		{`"{substr("abcdef", -2, 5)}{substr("abcdef", 10, 2)}|{substr("abcdef", 2, -1)}"`, "ef|"},
		{`"{stem("src/a.b.txt")} {ext("src/.hidden")} {ext("src/x.")}"`, "a.b  ."},
		{`"{pathjoin("out", "", "a.txt")}"`, "out/a.txt"},
		{`map(["a"], "100%%-%")`, "100%-a"},
		{`"{int("-007")}{indexof([1, "a"], "a")}"`, "-71"},
		{`"{sum(range(5))} {join(sort(["b", "a"]), "")} {join(uniq([1, 1, 2]), ",")}"`, "10 ab 1,2"},
		{`"{join(flatten([[1], 2, [3]]), "")} {len(zip([1,2],[3]))} {has([[1]], [1])}"`, "123 1 true"},
		{`"{join(filter(["a.txt", "b.c"], "*.txt"), "")}{join(reject(["a.txt", "b.c"], "*.txt"), "")}"`, "a.txtb.c"},
	}
	for _, tc := range tests {
		got, errText := evalDefault(map[string]string{"main.kiln": "default " + tc.expr + "\n"})
		if errText != "" || len(got) != 1 || got[0] != tc.want {
			t.Errorf("%s = %q (err %q), want %q", tc.expr, got, errText, tc.want)
		}
	}
}

func TestEvalErrors(t *testing.T) {
	tests := []struct {
		src, want string
	}{
		{`default "a" + 1`, "E_TYPE operator +: expected int, got str"},
		{`default 5["a"]`, "E_TYPE index: expected int, got str"},
		{`default [][0]`, "E_ARG fn index: out of range"},
		{`default 1 / 0`, "E_DIV_ZERO"},
		{`default "{[1]}"`, "E_INTERP list"},
		{`default nope(undefined)`, "E_UNKNOWN_FUNC nope"},
		{`default upper(undefined, 2)`, "E_UNKNOWN_VAR undefined"},
		{`default upper("a", 2)`, "E_ARITY fn upper: expected 1, got 2"},
		{`default pathjoin()`, "E_ARITY fn pathjoin: expected 1-8, got 0"},
		{`default upper(1)`, "E_TYPE fn upper argument 1: expected str, got int"},
		{`default len(1)`, "E_TYPE fn len argument 1: expected str|list, got int"},
		{`default join([[1]], "")`, "E_TYPE fn join element 0: expected str|int, got list"},
		{`default filter([1], "")`, "E_ARG fn filter: bad pattern"},
		{`default first([])`, "E_ARG fn first: empty list"},
		{`default int("+1")`, "E_ARG fn int: bad integer"},
		{`default int("99999999999999999999")`, "E_ARG fn int: bad integer"},
		{`default 1 |> cost`, "E_UNKNOWN_FUNC cost"},
		{"let x = 1\nlet x = 2", "E_REDEFINE x"},
		{`set x = 1`, "E_SET_UNDEFINED x"},
		{`default 1`, "E_TYPE default: expected strlist, got int"},
		{`default ["a", 1]`, "E_TYPE default: expected strlist, got int"},
		{`abort "boom {1}"`, "E_ABORT boom 1"},
		{`when 1 {` + "\n}", "E_TYPE when condition: expected bool, got int"},
		{`each x in "a" {` + "\n}", "E_TYPE each subject: expected list, got str"},
		{`include "nope.kiln"`, "E_INCLUDE_MISSING nope.kiln"},
		{`include "bad path"`, "E_BAD_PATH bad path"},
		{`include "main.kiln"`, "E_INCLUDE_CYCLE main.kiln"},
		{`use nope()`, "E_UNKNOWN_RULE nope"},
		{`phony a = "@bad-name"`, "E_BAD_PATH @bad-name"},
		{"phony a = []\nphony a = []", "E_DUP_PHONY a"},
	}
	for _, tc := range tests {
		_, errText := evalDefault(map[string]string{"main.kiln": tc.src + "\n"})
		if errText != tc.want {
			t.Errorf("%q: got %q, want %q", tc.src, errText, tc.want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	tests := []struct {
		name, src string
		line      int
	}{
		{"lexical beats grammar", "let = 1\nlet x = \"abc\n", 2},
		{"unterminated in multi-line call", "let b = f(\n  \"unterminated\n)\n", 1},
		{"open bracket at eof", "\nlet a = f(1,\n 2\n", 2},
		{"negative depth", "let a = 1)\n", 1},
		{"bare pipe", "let a = 1 | 2\n", 1},
		{"reserved variable", "let in = 1\n", 1},
		{"reserved as value", "let a = step\n", 1},
		{"step field outside step", "out \"x\"\n", 1},
		{"statement inside step", "step {\n let a = 1\n}\n", 2},
		{"unterminated block innermost", "when true {\n each x in [1] {\n", 2},
		{"unterminated elsewhen", "when true {\n} elsewhen false {\n", 2},
		{"stray terminator", "let a = 1\n}\n", 2},
		{"otherwise after otherwise", "when true {\n} otherwise {\n} otherwise {\n}\n", 3},
		{"elsewhen after otherwise", "when true {\n} otherwise {\n} elsewhen true {\n}\n", 3},
		{"elsewhen closing each", "each x in [] {\n} otherwise {\n}\n", 2},
		{"lone brace", "{\n", 1},
		{"bad escape", "let a = 1\nlet b = \"\\q\"\n", 2},
		{"lone close brace in string", "let a = \"}\"\n", 1},
		{"empty interpolation", "let a = \"{ }\"\n", 1},
		{"interpolation junk", "let a = \"{1 2}\"\n", 1},
		{"call on non-ident", "let a = f(1)(2)\n", 1},
		{"positional after keyword", "use r(a = 1, 2)\n", 1},
		{"duplicate param", "rule r(a, a) {\n}\n", 1},
		{"default before required", "rule r(a = 1, b) {\n}\n", 1},
		{"each same names", "each a, a in [] {\n}\n", 1},
		{"trailing tokens", "let a = 1 2\n", 1},
		{"syntax error in dead branch", "when false {\n let = 1\n}\n", 2},
		{"comment hides nothing in string", "let a = \"#\" #x\nlet = 2\n", 2},
	}
	for _, tc := range tests {
		_, err := parseFile(tc.src)
		se, ok := err.(*syntaxError)
		if !ok || se.line != tc.line {
			t.Errorf("%s: got %v, want syntax error on line %d", tc.name, err, tc.line)
		}
	}
}

func TestParseOK(t *testing.T) {
	src := `# comment
let xs = [
  1,   # one
  2,
]
let s = "a # not a comment {xs[0]}"
rule r(a, b = a ~ "x",) {
  step {
    out "out/{a}"
    cmd write(b)
  }
}
when true {
} elsewhen false {
} otherwise {
}
use r("p", b = "q",)
`
	if _, err := parseFile(src); err != nil {
		t.Fatal(err)
	}
}

func TestScopesAndRules(t *testing.T) {
	src := `
let n = 1
rule r(a, b = a + n) {
  set n = n + 10
  default "{a}:{b}:{n}"
}
let n2 = 5
each i, x in [7, 8] {
  let n = x
  use r(i)
}
when n == 21 {
  default "after"
}
use r(b = 0, a = 9)
`
	got, errText := evalDefault(map[string]string{"main.kiln": src})
	want := []string{"0:1:11", "1:12:21", "after", "9:0:31"}
	if errText != "" || !reflect.DeepEqual(got, want) {
		// n inside rule body refers to the rule's defining scope (root), not the loop's.
		t.Errorf("got %q (err %q), want %q", got, errText, want)
	}
}

func TestRuleErrors(t *testing.T) {
	pre := "rule r(a, b = 1) {\n}\n"
	tests := []struct{ use, want string }{
		{`use r()`, "E_ARG rule r: missing argument a"},
		{`use r(1, 2, 3)`, "E_ARITY rule r: expected 2, got 3"},
		{`use r(1, c = 2)`, "E_ARG rule r: unknown argument c"},
		{`use r(1, a = 2)`, "E_ARG rule r: duplicate argument a"},
		{`use r(1, b = 2, b = 3)`, "E_ARG rule r: duplicate argument b"},
	}
	for _, tc := range tests {
		_, errText := evalDefault(map[string]string{"main.kiln": pre + tc.use + "\n"})
		if errText != tc.want {
			t.Errorf("%s: got %q, want %q", tc.use, errText, tc.want)
		}
	}
	_, errText := evalDefault(map[string]string{"main.kiln": "rule r() {\n}\nrule r() {\n}\n"})
	if errText != "E_REDEFINE r" {
		t.Errorf("got %q", errText)
	}
}

func TestRuleRecursion(t *testing.T) {
	src := "let n = 0\nrule r() {\n use r()\n}\nuse r()\n"
	if _, errText := evalDefault(map[string]string{"main.kiln": src}); errText != "E_RULE_RECURSION r" {
		t.Errorf("got %q", errText)
	}
}

func TestGlobFunction(t *testing.T) {
	files := map[string]string{
		"main.kiln":     `default glob("src/**/*.txt") ++ glob("lib/**")`,
		"src/b.txt":     "",
		"src/a.txt":     "",
		"src/x/c.txt":   "",
		"src/n.md":      "",
		"lib":           "",
		"out/src/z.txt": "",
		".kiln-state":   "",
	}
	got, errText := evalDefault(files)
	want := []string{"src/a.txt", "src/b.txt", "src/x/c.txt", "lib"}
	if errText != "" || !reflect.DeepEqual(got, want) {
		t.Errorf("got %q (err %q), want %q", got, errText, want)
	}
}

func TestIncludeRunsInCurrentScope(t *testing.T) {
	files := map[string]string{
		"main.kiln": "let mode = \"fast\"\ninclude \"tune.kiln\"\ndefault \"{mode}{extra}\"\n",
		"tune.kiln": "set mode = \"slow\"\nlet extra = 1\n",
	}
	got, errText := evalDefault(files)
	if errText != "" || !reflect.DeepEqual(got, []string{"slow1"}) {
		t.Errorf("got %q (err %q)", got, errText)
	}
	files["main.kiln"] += "include \"tune.kiln\"\n"
	if _, errText := evalDefault(files); errText != "E_REDEFINE extra" {
		t.Errorf("second include: %q", errText)
	}
	files["tune.kiln"] = "include \"main.kiln\"\n"
	if _, errText := evalDefault(files); errText != "E_INCLUDE_CYCLE main.kiln" {
		t.Errorf("cycle: %q", errText)
	}
}

func TestParseErrorFileAndLineInInclude(t *testing.T) {
	files := map[string]string{
		"main.kiln": "let a = 1\ninclude \"b.kiln\"\n",
		"b.kiln":    "\n\nlet = 2\n",
	}
	if _, errText := evalDefault(files); errText != "E_PARSE b.kiln:3" {
		t.Errorf("got %q", errText)
	}
}

func TestStepErrors(t *testing.T) {
	tests := []struct{ step, want string }{
		{`out "out/a"`, "E_STEP_FIELD missing cmd"},
		{`cmd write("x")`, "E_STEP_FIELD missing out"},
		{"out \"out/a\"\ncmd write(\"x\")\ncmd write(\"y\")", "E_STEP_FIELD duplicate cmd"},
		{"out \"out/a\"\ncost 1\ncost 1 / 0", "E_STEP_FIELD duplicate cost"},
		{"out \"out/a\"\ncmd write(\"x\")\ncost -1", "E_ARG field cost: negative"},
		{"out \"out/a\"\ncost \"1\"", "E_TYPE field cost: expected int, got str"},
		{"out 1", "E_TYPE field out: expected strlist, got int"},
		{"out \"a/b\"\ncmd write(\"x\")", "E_OUTPUT_PATH a/b"},
		{"out [\"bad path\"]\ncmd write(\"x\")", "E_BAD_PATH bad path"},
		{"out \"out/a\"\nin \"@bad-\"\ncmd write(\"x\")", "E_BAD_PATH @bad-"},
		{"out \"out/a\"\ncmd nope()", "E_UNKNOWN_CMD nope"},
		{"out \"out/a\"\ncmd grep()", "E_ARITY cmd grep: expected 1, got 0"},
		{"out \"out/a\"\ncmd indent(\"x\")", "E_TYPE cmd indent argument 1: expected int, got str"},
		{"out \"out/a\"\nin \"main.kiln\"\ncmd write(\"x\")", "E_CMD_SHAPE write: expected inputs 0-0, got 1"},
		{"out \"out/a\"\nin \"@p\"\ncmd write(\"x\")", ""},
		{"out [\"out/a\", \"out/b\"]\ncmd write(\"x\")", "E_CMD_SHAPE write: expected outputs 1, got 2"},
		{"out \"out/a\"\ncmd write(\"x\")\ndepfile \"out/d\"", "E_CMD_SHAPE write: depfile not allowed"},
		{"out \"out/a\"\nin \"main.kiln\"\ncmd preprocess()", "E_CMD_SHAPE preprocess: depfile required"},
		{"out \"out/a\"\nin \"main.kiln\"\ncmd replace(\"\", \"x\")", "E_ARG cmd replace: empty pattern"},
	}
	for _, tc := range tests {
		src := "step {\n" + tc.step + "\n}\n"
		_, errText := evalDefault(map[string]string{"main.kiln": src})
		if errText != tc.want {
			t.Errorf("%q: got %q, want %q", tc.step, errText, tc.want)
		}
	}
}

func TestStepSerialsAndDefaults(t *testing.T) {
	src := `
each n in ["a", "b"] {
  step {
    out "out/{n}"
    cmd write(n)
    cost 4
  }
}
step {
  out "out/c"
  depfile "out/c.d"
  in "main.kiln"
  cmd preprocess()
}
`
	p, err := Evaluate(workspace(map[string]string{"main.kiln": src}), "main.kiln")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Steps) != 3 {
		t.Fatalf("steps = %d", len(p.Steps))
	}
	for i, s := range p.Steps {
		if s.Serial != i {
			t.Errorf("serial %d = %d", i, s.Serial)
		}
	}
	if s := p.Steps[0]; s.Cost != 4 || s.Command != `write("a")` {
		t.Errorf("step 0 = %+v", s)
	}
	if s := p.Steps[2]; s.Cost != 6 || !reflect.DeepEqual(s.AllOutputs(), []string{"out/c", "out/c.d"}) {
		t.Errorf("step 2 = %+v", s)
	}
}
