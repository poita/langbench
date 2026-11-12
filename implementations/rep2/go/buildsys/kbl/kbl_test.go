package kbl

import (
	"errors"
	"strings"
	"testing"

	"buildsys/kerr"
	"buildsys/vfs"
)

// evalSrc evaluates src as main.kiln (with extra files) and returns the error
// rendered as "KIND detail", or "" on success.
func evalSrc(t *testing.T, src string, files ...string) (*Result, string) {
	t.Helper()
	fs := vfs.New()
	fs.Write(MainFile, src)
	for i := 0; i+1 < len(files); i += 2 {
		fs.Write(files[i], files[i+1])
	}
	res, err := Evaluate(fs, MainFile)
	if err == nil {
		return res, ""
	}
	var ke *kerr.Error
	if !errors.As(err, &ke) {
		t.Fatalf("non-kerr error %v", err)
	}
	return nil, ke.Error()
}

// value evaluates a scalar expression by aborting with its text.
func value(t *testing.T, expr string) string {
	t.Helper()
	_, msg := evalSrc(t, "abort str("+expr+")\n")
	return strings.TrimPrefix(strings.TrimPrefix(msg, "E_ABORT"), " ")
}

func TestExpressions(t *testing.T) {
	tests := []struct{ expr, want string }{
		{"1 + 2 * 3", "7"},
		{"(1 + 2) * 3", "9"},
		{"-7 / 2", "-3"},
		{"-7 % 3", "-1"},
		{"7 % -3", "1"},
		{"2 - 3 - 4", "-5"},
		{`"a" ~ "b" ~ "c"`, "abc"},
		{"1 < 2 && 2 < 3", "true"},
		{"false || true && false", "false"},
		{`true || nope`, "true"},
		{`false && nope`, "false"},
		{`1 == 1 == true`, "true"},
		{`[1, [2]] == [1, [2]]`, "true"},
		{`"a" < "b"`, "true"},
		{`"ab" < "a"`, "false"},
		{`true < 0`, "true"},
		{`5 < "a"`, "true"},
		{`"z" < []`, "true"},
		{`[1, 2] < [1, 3]`, "true"},
		{`[1] < [1, 0]`, "true"},
		{`!false`, "true"},
		{`len([1, 2] ++ [3])`, "3"},
		{`"hello"[1]`, "e"},
		{`"hello"[-1]`, "o"},
		{`[1, 2, 3][-3]`, "1"},
		{`"x" |> upper`, "X"},
		{`"a,b" |> split(",") |> join("-")`, "a-b"},
		{`"{1 + 1}-{true}-{"q"}"`, "2-true-q"},
		{`"{{x}}"`, "{x}"},
		{`'a\n{x}''b'`, `a\n{x}'b`},
		{`"\t\0\\\"" |> len`, "4"},
		{`"{join(["a", "b"], ", ")}"`, "a, b"},
		{`"é" |> len`, "2"},
		{`upper("é")`, "é"},
	}
	for _, tc := range tests {
		if got := value(t, tc.expr); got != tc.want {
			t.Errorf("%s = %q, want %q", tc.expr, got, tc.want)
		}
	}
}

func TestBuiltins(t *testing.T) {
	tests := []struct{ expr, want string }{
		{`len("abc")`, "3"},
		{`count([1, 2])`, "2"},
		{`trim(" \t\r\nx y\n ")`, "x y"},
		{`replace("aaa", "aa", "b")`, "ba"},
		{`starts_with("abc", "")`, "true"},
		{`ends_with("abc", "bc")`, "true"},
		{`contains("abc", "d")`, "false"},
		{`substr("abcdef", 1, 3)`, "bcd"},
		{`substr("abcdef", -2, 5)`, "ef"},
		{`substr("abcdef", 10, 2)`, ""},
		{`substr("abcdef", 2, -1)`, ""},
		{`join(split("a,,b", ","), "|")`, "a||b"},
		{`len(split("", ","))`, "1"},
		{`int("-007") + 1`, "-6"},
		{`dirname("a/b/c")`, "a/b"},
		{`dirname("c")`, ""},
		{`basename("a/b/c")`, "c"},
		{`stem("src/a.b.txt")`, "a.b"},
		{`ext("src/a.b.txt")`, ".txt"},
		{`stem("src/.hidden")`, ".hidden"},
		{`ext("src/.hidden")`, ""},
		{`ext("src/x.")`, "."},
		{`pathjoin("out", "", "a.txt")`, "out/a.txt"},
		{`pathjoin("out/")`, "out/"},
		{`join(map(["a"], "100%%-%"), "")`, "100%-a"},
		{`join(filter(["a.txt", "b.c", "d/e.txt"], "*.txt"), ",")`, "a.txt"},
		{`join(reject(["a.txt", "b.c"], "*.txt"), ",")`, "b.c"},
		{`join(sort(["b", "a", "c"]), "")`, "abc"},
		{`join(sort([3, 1, 2]), "")`, "123"},
		{`join(uniq([1, 2, 1, 3, 2]), "")`, "123"},
		{`len(uniq([[1], [1], "1", 1]))`, "3"},
		{`join(reverse([1, 2, 3]), "")`, "321"},
		{`first([7, 8])`, "7"},
		{`last([7, 8])`, "8"},
		{`join(slice([1, 2, 3, 4], 1, 2), "")`, "23"},
		{`has([[1], 2], [1])`, "true"},
		{`indexof(["a", "b"], "b")`, "1"},
		{`indexof(["a"], "z")`, "-1"},
		{`join(range(4), "")`, "0123"},
		{`sum([1, 2, 3])`, "6"},
		{`sum([])`, "0"},
		{`len(flatten([[1, 2], 3, [[4]]]))`, "4"},
		{`len(zip([1, 2, 3], ["a"]))`, "1"},
		{`is_str("")`, "true"},
		{`is_int("")`, "false"},
		{`is_bool(false)`, "true"},
		{`is_list([])`, "true"},
		{`str(12) ~ str(true) ~ str("x")`, "12truex"},
	}
	for _, tc := range tests {
		if got := value(t, tc.expr); got != tc.want {
			t.Errorf("%s = %q, want %q", tc.expr, got, tc.want)
		}
	}
}

func TestErrors(t *testing.T) {
	tests := []struct{ src, want string }{
		{`abort "x"`, "E_ABORT x"},
		{`abort 1`, "E_TYPE abort message: expected str, got int"},
		{`abort "a" + [1]`, "E_TYPE operator +: expected int, got str"},
		{`abort 5["a"]`, "E_TYPE index: expected int, got str"},
		{`abort 5[1]`, "E_TYPE index target: expected str|list, got int"},
		{`abort [1][1]`, "E_ARG fn index: out of range"},
		{`abort [1][-2]`, "E_ARG fn index: out of range"},
		{`abort nope(undefined)`, "E_UNKNOWN_FUNC nope"},
		{`abort upper(undefined, 2)`, "E_UNKNOWN_VAR undefined"},
		{`abort upper("a", "b")`, "E_ARITY fn upper: expected 1, got 2"},
		{`abort pathjoin()`, "E_ARITY fn pathjoin: expected 1-8, got 0"},
		{`abort upper(1)`, "E_TYPE fn upper argument 1: expected str, got int"},
		{`abort len(1)`, "E_TYPE fn len argument 1: expected str|list, got int"},
		{`abort str([1])`, "E_TYPE fn str argument 1: expected str|int|bool, got list"},
		{`abort join([[1]], ",")`, "E_TYPE fn join element 0: expected str|int, got list"},
		{`abort sum([1, "a"])`, "E_TYPE fn sum element 1: expected int, got str"},
		{`abort filter([1], "")`, "E_ARG fn filter: bad pattern"},
		{`abort filter([1], "*")`, "E_TYPE fn filter element 0: expected str, got int"},
		{`abort glob("[")`, "E_ARG fn glob: bad pattern"},
		{`abort replace("a", "", "b")`, "E_ARG fn replace: empty pattern"},
		{`abort split("a", "")`, "E_ARG fn split: empty separator"},
		{`abort int("1x")`, "E_ARG fn int: bad integer"},
		{`abort int("99999999999999999999")`, "E_ARG fn int: bad integer"},
		{`abort first([])`, "E_ARG fn first: empty list"},
		{`abort range(-1)`, "E_ARG fn range: negative"},
		{`abort 1 / 0`, "E_DIV_ZERO"},
		{`abort 1 % 0`, "E_DIV_ZERO"},
		{`abort "{[1]}"`, "E_INTERP list"},
		{"let a = 1\nlet a = 2", "E_REDEFINE a"},
		{"set a = 1", "E_SET_UNDEFINED a"},
		{"let a = undefined\nlet a = 1", "E_UNKNOWN_VAR undefined"},
		{"let a = 1\nwhen a { }", "E_PARSE main.kiln:2"},
		{"let a = 1\nwhen a {\n}", "E_TYPE when condition: expected bool, got int"},
		{"each x in 1 {\n}", "E_TYPE each subject: expected list, got int"},
		{`include "nope.kiln"`, "E_INCLUDE_MISSING nope.kiln"},
		{`include "main.kiln"`, "E_INCLUDE_CYCLE main.kiln"},
		{`include "a b"`, "E_BAD_PATH a b"},
		{`include 1`, "E_TYPE include path: expected str, got int"},
		{"use nothing()", "E_UNKNOWN_RULE nothing"},
		{"phony a = []\nphony a = []", "E_DUP_PHONY a"},
		{"phony a = [\"a b\"]\nphony a = []", "E_BAD_PATH a b"},
		{"phony a = 1", "E_TYPE phony a: expected strlist, got int"},
		{"default [\"a\", 1]", "E_TYPE default: expected strlist, got int"},
		{"rule r(a) {\n}\nrule r(b) {\n}", "E_REDEFINE r"},
	}
	for _, tc := range tests {
		if _, got := evalSrc(t, tc.src); got != tc.want {
			t.Errorf("%q: got %q, want %q", tc.src, got, tc.want)
		}
	}
}

func TestParseErrorLines(t *testing.T) {
	tests := []struct {
		name, src string
		line      int // 0 = no error
	}{
		{"unterminated literal in group", "let b = f(\n  \"unterminated\n)\n", 1},
		{"negative depth", "let a = 1\nlet b = 2)\n", 2},
		{"open at eof", "\nlet a = (1\n+ 2\n", 2},
		{"lexical beats grammar", "let = 1\nlet x = \"abc\n", 2},
		{"bare pipe", "let a = 1 | 2\n", 1},
		{"bare amp", "let a = 1 & 2\n", 1},
		{"bad escape", "let a = \"\\q\"\n", 1},
		{"lone brace", "let a = \"}\"\n", 1},
		{"empty interp", "let a = \"{ }\"\n", 1},
		{"interp leftovers", "let a = \"{1 2}\"\n", 1},
		{"reserved var", "let cost = 1\n", 1},
		{"reserved in expr", "let a = in\n", 1},
		{"call on non ident", "let a = (upper)(1)\n", 1},
		{"unterminated block", "let a = 1\nwhen true {\nlet b = 1\n", 2},
		{"innermost block", "when true {\neach x in [] {\n", 2},
		{"stray close", "let a = 1\n}\n", 2},
		{"elsewhen after otherwise", "when true {\n} otherwise {\n} elsewhen true {\n}\n", 3},
		{"otherwise on each", "each x in [] {\n} otherwise {\n}\n", 2},
		{"lone brace line", "{\n", 1},
		{"step field outside step", "out \"out/a\"\n", 1},
		{"statement inside step", "step {\nlet a = 1\n}\n", 2},
		{"positional after keyword", "use r(a = 1, 2)\n", 1},
		{"duplicate param", "rule r(a, a) {\n}\n", 1},
		{"default order", "rule r(a = 1, b) {\n}\n", 1},
		{"same loop names", "each a, a in [] {\n}\n", 1},
		{"trailing tokens", "let a = 1 2\n", 1},
		{"comment ok", "let a = 1 # fine\n# only comment\n", 0},
		{"hash in string", "let a = \"#x\"\n", 0},
		{"call named reserved", "let a = 1 |> cost\n", 0},
		{"use reserved rule", "use cost()\n", 0},
		{"trailing commas", "let a = f(1,)\nlet b = [1,]\n", 0},
		{"nested interp literal", "let a = \"{join(xs, \", \")}\"\n", 0},
		{"multiline list", "let a = [\n 1,\n 2,\n]\n", 0},
		{"when chain", "when true {\n} elsewhen false {\n} otherwise {\n}\n", 0},
		{"unterminated at elsewhen", "when true {\n} elsewhen false {\n", 2},
	}
	for _, tc := range tests {
		_, err := Parse(tc.src)
		got := 0
		if err != nil {
			got = err.(*ParseError).Line
		}
		if got != tc.line {
			t.Errorf("%s: error line %d, want %d", tc.name, got, tc.line)
		}
	}
}

func TestScoping(t *testing.T) {
	src := `
let x = 1
rule r(p) {
    set x = x + p
}
let y = 10
when true {
    let x = 100
    set x = x + 1
    set y = y + x
}
use r(5)
use r(p = 6)
abort "{x} {y}"
`
	if _, got := evalSrc(t, src); got != "E_ABORT 12 111" {
		t.Errorf("got %q", got)
	}
	// A rule's scope is its defining scope, held by reference.
	src = `
rule r() {
    abort "{later}"
}
let later = "seen"
use r()
`
	if _, got := evalSrc(t, src); got != "E_ABORT seen" {
		t.Errorf("got %q", got)
	}
	// Include shares the scope; including twice redefines.
	if _, got := evalSrc(t, "include \"a.kiln\"\nabort \"{v}\"", "a.kiln", "let v = 4\n"); got != "E_ABORT 4" {
		t.Errorf("got %q", got)
	}
	if _, got := evalSrc(t, "include \"a.kiln\"\ninclude \"a.kiln\"", "a.kiln", "let v = 4\n"); got != "E_REDEFINE v" {
		t.Errorf("got %q", got)
	}
	// Syntax errors in an included file name that file.
	if _, got := evalSrc(t, "include \"a.kiln\"", "a.kiln", "\nlet = 1\n"); got != "E_PARSE a.kiln:2" {
		t.Errorf("got %q", got)
	}
}

func TestUseBinding(t *testing.T) {
	prelude := "rule r(a, b = a ~ \"!\", c = 3) {\n    abort \"{a} {b} {c}\"\n}\n"
	tests := []struct{ use, want string }{
		{`use r("x")`, "E_ABORT x x! 3"},
		{`use r("x", "y", 9)`, "E_ABORT x y 9"},
		{`use r(c = 1, a = "q")`, "E_ABORT q q! 1"},
		{`use r("a", "b", 1, 2)`, "E_ARITY rule r: expected 3, got 4"},
		{`use r()`, "E_ARG rule r: missing argument a"},
		{`use r("a", zz = 1)`, "E_ARG rule r: unknown argument zz"},
		{`use r("a", a = 1)`, "E_ARG rule r: duplicate argument a"},
		{`use r(undefined, 1, 2, 3)`, "E_UNKNOWN_VAR undefined"},
	}
	for _, tc := range tests {
		if _, got := evalSrc(t, prelude+tc.use+"\n"); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.use, got, tc.want)
		}
	}
}

func TestRuleRecursion(t *testing.T) {
	src := "let depth = 0\nrule r(n) {\n  when n < LIMIT {\n    use r(n + 1)\n  }\n}\nuse r(1)\n"
	if _, got := evalSrc(t, strings.Replace(src, "LIMIT", "64", 1)); got != "" {
		t.Errorf("depth 64 rejected: %q", got)
	}
	if _, got := evalSrc(t, strings.Replace(src, "LIMIT", "65", 1)); got != "E_RULE_RECURSION r" {
		t.Errorf("depth 65: got %q", got)
	}
}

func TestStepValidation(t *testing.T) {
	step := func(body string) string { return "step {\n" + body + "\n}\n" }
	tests := []struct{ name, src, want string }{
		{"missing cmd", step(`out "out/a"`), "E_STEP_FIELD missing cmd"},
		{"missing out", step(`cmd write("x")`), "E_STEP_FIELD missing out"},
		{"duplicate cmd", step("out \"out/a\"\ncmd write(\"x\")\ncmd write(\"y\")"), "E_STEP_FIELD duplicate cmd"},
		{"duplicate cost first", step("cost 1\ncost undefined"), "E_STEP_FIELD duplicate cost"},
		{"duplicate depfile", step("depfile \"out/d\"\ndepfile \"out/e\""), "E_STEP_FIELD duplicate depfile"},
		{"negative cost", step("cost -1"), "E_ARG field cost: negative"},
		{"cost type", step(`cost "a"`), "E_TYPE field cost: expected int, got str"},
		{"out type", step("out 1"), "E_TYPE field out: expected strlist, got int"},
		{"out list type", step(`out ["a", 1, []]`), "E_TYPE field out: expected strlist, got int"},
		{"unknown cmd", step("cmd nope()"), "E_UNKNOWN_CMD nope"},
		{"cmd arity", step("cmd grep()"), "E_ARITY cmd grep: expected 1, got 0"},
		{"cmd type", step("cmd indent(\"a\")"), "E_TYPE cmd indent argument 1: expected int, got str"},
		{"bad out path", step("out \"out/a b\"\ncmd write(\"\")"), "E_BAD_PATH out/a b"},
		{"out path", step("out \"src/a\"\ncmd write(\"\")"), "E_OUTPUT_PATH src/a"},
		{"first bad path wins", step("out [\"src/a\", \"a b\"]\ncmd write(\"\")"), "E_OUTPUT_PATH src/a"},
		{"depfile path", step("out \"out/a\"\ndepfile \"x\"\ncmd preprocess()"), "E_OUTPUT_PATH x"},
		{"bad input", step("out \"out/a\"\nin \"@\"\ncmd write(\"\")"), "E_BAD_PATH @"},
		{"input count", step("out \"out/a\"\ncmd copy()"), "E_CMD_SHAPE copy: expected inputs 1-1, got 0"},
		{"write inputs", step("out \"out/a\"\nin \"x\"\ncmd write(\"\")"), "E_CMD_SHAPE write: expected inputs 0-0, got 1"},
		{"concat inputs", step("out \"out/a\"\ncmd concat()"), "E_CMD_SHAPE concat: expected inputs 1-N, got 0"},
		{"output count", step("out [\"out/a\", \"out/b\"]\ncmd write(\"\")"), "E_CMD_SHAPE write: expected outputs 1, got 2"},
		{"depfile required", step("out \"out/a\"\nin \"x\"\ncmd preprocess()"), "E_CMD_SHAPE preprocess: depfile required"},
		{"depfile not allowed", step("out \"out/a\"\ndepfile \"out/d\"\ncmd write(\"\")"), "E_CMD_SHAPE write: depfile not allowed"},
		{"cmd arg check", step("out \"out/a\"\nin \"x\"\ncmd replace(\"\", \"b\")"), "E_ARG cmd replace: empty pattern"},
		{"phony inputs not counted", step("out \"out/a\"\nin [\"@p\"]\ncmd write(\"\")"), ""},
	}
	for _, tc := range tests {
		if _, got := evalSrc(t, tc.src); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestStepResult(t *testing.T) {
	res, err := evalSrc(t, `
step {
    out "out/a"
    in "src/x"
    in "@p"
    after "src/z"
    depfile "out/a.d"
    cmd preprocess()
}
rule r(n) {
    step {
        out "out/{n}"
        cmd write("{n}")
        cost n
    }
}
each i in range(2) {
    use r(i)
}
phony p = []
default ["out/a", "out/1"]
`)
	if err != "" {
		t.Fatal(err)
	}
	if len(res.Steps) != 3 {
		t.Fatalf("got %d steps", len(res.Steps))
	}
	s := res.Steps[0]
	if s.Serial != 0 || s.Primary() != "out/a" || s.Cost != 6 {
		t.Errorf("step 0 = %+v", s)
	}
	if got := strings.Join(s.FileInputs, ","); got != "src/x" {
		t.Errorf("file inputs = %s", got)
	}
	if got := strings.Join(s.FullOutputs, ","); got != "out/a,out/a.d" {
		t.Errorf("full outputs = %s", got)
	}
	if res.Steps[2].Serial != 2 || res.Steps[2].Cost != 1 || res.Steps[2].Canonical() != `write("1")` {
		t.Errorf("step 2 = %+v", res.Steps[2])
	}
	if len(res.Phonies) != 1 || strings.Join(res.Defaults, ",") != "out/a,out/1" {
		t.Errorf("phonies %v defaults %v", res.Phonies, res.Defaults)
	}
}

func TestGlobFunction(t *testing.T) {
	fs := vfs.New()
	fs.Write(MainFile, "abort join(glob(\"src/**/*.txt\"), \",\")\n")
	for _, p := range []string{"src/b.txt", "src/a.txt", "src/sub/c.txt", "src/n.md", "out/x.txt", ".kiln-state"} {
		fs.Write(p, "")
	}
	_, err := Evaluate(fs, MainFile)
	if err == nil || err.Error() != "E_ABORT src/a.txt,src/b.txt,src/sub/c.txt" {
		t.Errorf("got %v", err)
	}
}
