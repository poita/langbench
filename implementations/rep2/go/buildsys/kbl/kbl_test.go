package kbl

import (
	"reflect"
	"strings"
	"testing"

	"kiln/vfs"
)

// eval runs main.kiln (plus extra files) and returns the program or the
// error text.
func eval(t *testing.T, main string, extra ...string) (*Program, string) {
	t.Helper()
	fs := vfs.New()
	fs.Write("main.kiln", []byte(main))
	for i := 0; i+1 < len(extra); i += 2 {
		fs.Write(extra[i], []byte(extra[i+1]))
	}
	p, err := Evaluate(fs)
	if err != nil {
		return nil, err.Error()
	}
	return p, ""
}

// value evaluates a single expression by writing it to a default.
func value(t *testing.T, expr string) string {
	t.Helper()
	p, e := eval(t, "default "+expr+"\n")
	if e != "" {
		return e
	}
	return strings.Join(p.Defaults, ",")
}

func TestExpressions(t *testing.T) {
	cases := map[string]string{
		`"a" ~ "b"`:                                 "ab",
		`"{1 + 2 * 3}"`:                             "7",
		`"{-7 / 2}{-7 % 2}"`:                        "-3-1",
		`"{{x}}"`:                                   "{x}",
		`'it''s {x}'`:                               "it's {x}",
		`"{join(["a", "b"], ", ")}"`:                "a, b",
		`"{1 < 2 && "a" < "b"}"`:                    "true",
		`"{[1, 2] < [1, 3]}"`:                       "true",
		`"{true < 0}"`:                              "true",
		`"{[1] ++ [2] == [1, 2]}"`:                  "true",
		`"x/y.tar.gz" |> stem`:                      "y.tar",
		`"a,b" |> split(",") |> join("+")`:          "a+b",
		`"{false && 1 / 0 == 0}"`:                   "false",
		`"{true || undefined}"`:                     "true",
		`"{substr("abcdef", -2, 5)}"`:               "ef",
		`"{"abc"[-1]}"`:                             "c",
		`"{ext("src/.hidden")}|{ext("a.")}"`:        "|.",
		`"{pathjoin("out", "", "a")}"`:              "out/a",
		`map(["a"], "100%%-%")`:                     "100%-a",
		`"{sort([3, "b", true, [1], "a"]) |> len}"`: "5",
		`"{uniq([1, "1", 1, [1], [1]]) |> len}"`:    "3",
		`"{indexof(["a", ["b"]], ["b"])}"`:          "1",
		`"{sum(range(5))}"`:                         "10",
		`"{zip([1, 2, 3], ["a", "b"]) |> len}"`:     "2",
		`"{flatten([[1], 2, [[3]]]) |> len}"`:       "3",
		`"{int("-007") + 1}"`:                       "-6",
		`"{upper("aé")}"`:                           "Aé",
		`"{trim("  x\n")}"`:                         "x",
		`"{replace("aaa", "aa", "b")}"`:             "ba",
	}
	for expr, want := range cases {
		if got := value(t, expr); got != want {
			t.Errorf("%s = %q, want %q", expr, got, want)
		}
	}
}

func TestExpressionErrors(t *testing.T) {
	cases := map[string]string{
		`"a" + [1]`:                  "E_TYPE operator +: expected int, got str",
		`5["a"]`:                     "E_TYPE index: expected int, got str",
		`5[0]`:                       "E_TYPE index target: expected str|list, got int",
		`[1][3]`:                     "E_ARG fn index: out of range",
		`1 / 0`:                      "E_DIV_ZERO",
		`"{[1]}"`:                    "E_INTERP list",
		`nope(undefined)`:            "E_UNKNOWN_FUNC nope",
		`upper(undefined, 2)`:        "E_UNKNOWN_VAR undefined",
		`upper("a", "b")`:            "E_ARITY fn upper: expected 1, got 2",
		`pathjoin()`:                 "E_ARITY fn pathjoin: expected 1-8, got 0",
		`upper(1)`:                   "E_TYPE fn upper argument 1: expected str, got int",
		`join([1, [2]], ",")`:        "E_TYPE fn join element 1: expected str|int, got list",
		`filter([1], "")`:            "E_ARG fn filter: bad pattern",
		`first([])`:                  "E_ARG fn first: empty list",
		`int("+1")`:                  "E_ARG fn int: bad integer",
		`int("9223372036854775808")`: "E_ARG fn int: bad integer",
		`1 |> cost`:                  "E_UNKNOWN_FUNC cost",
		`!1`:                         "E_TYPE operator !: expected bool, got int",
		`true && 1`:                  "E_TYPE operator &&: expected bool, got int",
		`range(-1)`:                  "E_ARG fn range: negative",
		`replace("a", "", "b")`:      "E_ARG fn replace: empty pattern",
	}
	for expr, want := range cases {
		if got := value(t, expr); got != want {
			t.Errorf("%s = %q, want %q", expr, got, want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	cases := []struct {
		src  string
		want string
	}{
		{"let = 1\nlet x = \"abc\n", "E_PARSE main.kiln:2"},
		{"let b = f(\n  \"unterminated\n)\n", "E_PARSE main.kiln:1"},
		{"let x = 1 |\n", "E_PARSE main.kiln:1"},
		{"let x = (1\n", "E_PARSE main.kiln:1"},
		{"let x = 1)\n", "E_PARSE main.kiln:1"},
		{"let cost = 1\n", "E_PARSE main.kiln:1"},
		{"\n\nwhen true {\n  let x = 1\n", "E_PARSE main.kiln:3"},
		{"when true {\n} otherwise {\n} elsewhen true {\n}\n", "E_PARSE main.kiln:3"},
		{"}\n", "E_PARSE main.kiln:1"},
		{"let x = \"a\\q\"\n", "E_PARSE main.kiln:1"},
		{"let x = \"{}\"\n", "E_PARSE main.kiln:1"},
		{"let x = \"a}\"\n", "E_PARSE main.kiln:1"},
		{"let x = f(1)(2)\n", "E_PARSE main.kiln:1"},
		{"out \"x\"\n", "E_PARSE main.kiln:1"},
		{"step {\n  let x = 1\n}\n", "E_PARSE main.kiln:2"},
		{"each a, a in [] {\n}\n", "E_PARSE main.kiln:1"},
		{"rule r(a = 1, b) {\n}\n", "E_PARSE main.kiln:1"},
		{"rule r(a, a) {\n}\n", "E_PARSE main.kiln:1"},
		{"use r(a = 1, 2)\n", "E_PARSE main.kiln:1"},
		{"{\n", "E_PARSE main.kiln:1"},
		{"let x = 1 # fine\nlet y = 2 2\n", "E_PARSE main.kiln:2"},
	}
	for _, c := range cases {
		if _, got := eval(t, c.src); got != c.want {
			t.Errorf("%q: got %q, want %q", c.src, got, c.want)
		}
	}
}

func TestCommentsAndBrackets(t *testing.T) {
	p, e := eval(t, "let xs = [ # first\n  \"a#b\", # second\n  \"c\",\n]\ndefault xs # done\n")
	if e != "" {
		t.Fatal(e)
	}
	if want := []string{"a#b", "c"}; !reflect.DeepEqual(p.Defaults, want) {
		t.Errorf("defaults = %v", p.Defaults)
	}
}

func TestScoping(t *testing.T) {
	src := `
let x = 1
when true {
    let x = 2
    set x = x + 10
}
let ys = []
each i, n in ["a", "b"] {
    set ys = ys ++ ["{i}{n}"]
}
default ys ++ ["{x}"]
`
	p, e := eval(t, src)
	if e != "" {
		t.Fatal(e)
	}
	if want := []string{"0a", "1b", "1"}; !reflect.DeepEqual(p.Defaults, want) {
		t.Errorf("defaults = %v", p.Defaults)
	}
	for src, want := range map[string]string{
		"let x = 1\nlet x = 2\n": "E_REDEFINE x",
		"set y = 1\n":            "E_SET_UNDEFINED y",
		"let x = y\nlet x = 1\n": "E_UNKNOWN_VAR y",
		"when 1 {\n}\n":          "E_TYPE when condition: expected bool, got int",
		"each x in 1 {\n}\n":     "E_TYPE each subject: expected list, got int",
		"abort \"n={1+1}\"\n":    "E_ABORT n=2",
	} {
		if _, got := eval(t, src); got != want {
			t.Errorf("%q: got %q, want %q", src, got, want)
		}
	}
}

func TestIncludeAndRules(t *testing.T) {
	_, got := eval(t, "include \"a.kiln\"\n", "a.kiln", "include \"main.kiln\"\n")
	if got != "E_INCLUDE_CYCLE main.kiln" {
		t.Errorf("got %q", got)
	}
	if _, got := eval(t, "include \"nope.kiln\"\n"); got != "E_INCLUDE_MISSING nope.kiln" {
		t.Errorf("got %q", got)
	}
	if _, got := eval(t, "include \"a.kiln\"\ninclude \"a.kiln\"\n", "a.kiln", "let x = 1\n"); got != "E_REDEFINE x" {
		t.Errorf("got %q", got)
	}
	if _, got := eval(t, "include \"a.kiln\"\n", "a.kiln", "let x = =\n"); got != "E_PARSE a.kiln:1" {
		t.Errorf("got %q", got)
	}

	rules := `
let counter = 0
rule r(a, b = a ~ "!") {
    default [a, b, "{counter}"]
}
set counter = 5
use r("x")
use r(b = "y", a = "z")
`
	p, e := eval(t, rules)
	if e != "" {
		t.Fatal(e)
	}
	if want := []string{"x", "x!", "5", "z", "y", "5"}; !reflect.DeepEqual(p.Defaults, want) {
		t.Errorf("defaults = %v", p.Defaults)
	}
	for src, want := range map[string]string{
		"use nope()\n":                        "E_UNKNOWN_RULE nope",
		"rule r(a) {\n}\nuse r()\n":           "E_ARG rule r: missing argument a",
		"rule r(a) {\n}\nuse r(1, 2)\n":       "E_ARITY rule r: expected 1, got 2",
		"rule r(a) {\n}\nuse r(b = 1)\n":      "E_ARG rule r: unknown argument b",
		"rule r(a) {\n}\nuse r(1, a = 2)\n":   "E_ARG rule r: duplicate argument a",
		"rule r() {\n}\nrule r() {\n}\n":      "E_REDEFINE r",
		"rule r() {\n  use r()\n}\nuse r()\n": "E_RULE_RECURSION r",
	} {
		if _, got := eval(t, src); got != want {
			t.Errorf("%q: got %q, want %q", src, got, want)
		}
	}
}

func TestSteps(t *testing.T) {
	src := `
step {
    out "out/a.txt"
    in ["src/a.txt", "@all"]
    after "src/a.txt"
    cmd wrap("<", ">")
    cost 7
}
step {
    out ["out/b.txt"]
    cmd write("x")
}
phony all = ["out/b.txt"]
`
	p, e := eval(t, src, "src/a.txt", "")
	if e != "" {
		t.Fatal(e)
	}
	a := p.Steps[0]
	if a.Serial != 0 || a.Cost != 7 || a.CmdStr != `wrap("<", ">")` || !reflect.DeepEqual(a.FileIns, []string{"src/a.txt"}) {
		t.Errorf("step 0 = %+v", a)
	}
	if b := p.Steps[1]; b.Serial != 1 || b.Cost != 1 {
		t.Errorf("step 1 = %+v", b)
	}
	if len(p.Phonies) != 1 || p.Phonies[0].Name != "all" {
		t.Errorf("phonies = %+v", p.Phonies)
	}

	step := func(body string) string { return "step {\n" + body + "\n}\n" }
	for src, want := range map[string]string{
		step("cmd write(\"x\")"):                                  "E_STEP_FIELD missing out",
		step("out \"out/x\""):                                     "E_STEP_FIELD missing cmd",
		step("out \"out/x\"\ncmd write(\"\")\ncmd write(\"\")"):   "E_STEP_FIELD duplicate cmd",
		step("out \"out/x\"\ncost 1\ncost nope"):                  "E_STEP_FIELD duplicate cost",
		step("out \"x\"\ncmd write(\"\")"):                        "E_OUTPUT_PATH x",
		step("out \"out/a b\"\ncmd write(\"\")"):                  "E_BAD_PATH out/a b",
		step("out \"out/x\"\ncmd bogus()"):                        "E_UNKNOWN_CMD bogus",
		step("out \"out/x\"\ncmd write()"):                        "E_ARITY cmd write: expected 1, got 0",
		step("out \"out/x\"\ncmd write(1)"):                       "E_TYPE cmd write argument 1: expected str, got int",
		step("out \"out/x\"\ncmd copy()"):                         "E_CMD_SHAPE copy: expected inputs 1-1, got 0",
		step("out [\"out/x\", \"out/y\"]\ncmd write(\"\")"):       "E_CMD_SHAPE write: expected outputs 1, got 2",
		step("out \"out/x\"\ncmd preprocess()\nin \"a\""):         "E_CMD_SHAPE preprocess: depfile required",
		step("out \"out/x\"\ncmd write(\"\")\ndepfile \"out/d\""): "E_CMD_SHAPE write: depfile not allowed",
		step("out \"out/x\"\ncmd write(\"\")\ncost -1"):           "E_ARG field cost: negative",
		step("out 3\ncmd write(\"\")"):                            "E_TYPE field out: expected strlist, got int",
		step("out [\"out/x\", 3]\ncmd write(\"\")"):               "E_TYPE field out: expected strlist, got int",
		step("out \"out/x\"\nin \"@a-b\"\ncmd write(\"\")"):       "E_BAD_PATH @a-b",
		step("out \"out/x\"\ncmd indent(-1)\nin \"a\""):           "E_ARG cmd indent: negative",
		"phony a = []\nphony a = []\n":                            "E_DUP_PHONY a",
		"phony a = [\"bad path\"]\n":                              "E_BAD_PATH bad path",
	} {
		if _, got := eval(t, src); got != want {
			t.Errorf("%q: got %q, want %q", src, got, want)
		}
	}
}

func TestGlobBuiltin(t *testing.T) {
	p, e := eval(t, `default glob("src/**/*.txt") ++ glob("*.kiln") ++ glob("out/**") ++ glob(".kiln-state")`,
		"src/b.txt", "", "src/a.txt", "", "src/sub/c.txt", "", "src/n.md", "", "out/x.txt", "", ".kiln-state", "")
	if e != "" {
		t.Fatal(e)
	}
	want := []string{"src/a.txt", "src/b.txt", "src/sub/c.txt", "main.kiln"}
	if !reflect.DeepEqual(p.Defaults, want) {
		t.Errorf("glob = %v, want %v", p.Defaults, want)
	}
	if _, got := eval(t, `default glob("[")`); got != "E_ARG fn glob: bad pattern" {
		t.Errorf("got %q", got)
	}
}

func TestBuiltinCount(t *testing.T) {
	if n := len(BuiltinNames()); n != 39 {
		t.Errorf("want 39 built-ins, got %d", n)
	}
}

func TestCompare(t *testing.T) {
	order := []Value{boolVal(false), boolVal(true), intVal(-1), intVal(2), strVal(""), strVal("a"),
		strVal("b"), listVal(nil), listVal([]Value{intVal(1)}), listVal([]Value{intVal(2)})}
	for i := range order {
		for j := range order {
			got := Compare(order[i], order[j])
			if (i < j) != (got < 0) || (i == j) != (got == 0) {
				t.Errorf("Compare(%d,%d) = %d", i, j, got)
			}
		}
	}
}
