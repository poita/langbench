package kbl_test

import (
	"strings"
	"testing"

	"buildsys/kbl"
	"buildsys/plan"
	"buildsys/vfs"
)

// eval evaluates src as main.kiln (plus extra files) and returns the plan or
// the rendered error.
func eval(t *testing.T, src string, extra ...string) (*plan.Plan, string) {
	t.Helper()
	fs := vfs.New()
	fs.Write("main.kiln", []byte(src))
	for i := 0; i+1 < len(extra); i += 2 {
		fs.Write(extra[i], []byte(extra[i+1]))
	}
	p, err := kbl.Evaluate(fs)
	if err != nil {
		return nil, err.Error()
	}
	return p, ""
}

// val evaluates `expr` through a single-step build file and returns the
// step's write() text, or the error.
func val(t *testing.T, expr string) string {
	t.Helper()
	p, e := eval(t, "step {\n out \"out/x\"\n cmd write("+expr+")\n}\n")
	if e != "" {
		return e
	}
	return p.Steps[0].Args[0].Str
}

func TestExpressions(t *testing.T) {
	cases := map[string]string{
		`"a" ~ "b"`:                            "ab",
		`"{1 + 2 * 3}"`:                        "7",
		`"{(1 + 2) * 3}"`:                      "9",
		`"{7 / 2} {-7 / 2} {7 % 3} {-7 % 3}"`:  "3 -3 1 -1",
		`"{1 < 2} {"a" < "b"} {[1] < [1, 0]}"`: "true true true",
		`"{true < 1} {1 < "a"} {"a" < []}"`:    "true true true",
		`"{[1, [2]] == [1, [2]]} {1 == "1"}"`:  "true false",
		`"{!false && true || false}"`:          "true",
		`"{true || undefined_var}"`:            "true",
		`"{false && undefined_var}"`:           "false",
		`"{{lit}} }} {{"`:                      "{lit} } {",
		`'it''s {x}\n'`:                        `it's {x}\n`,
		`"\\ \" \n \t \r \0"`:                  "\\ \" \n \t \r \x00",
		`"{join(["a", 1], "-")}"`:              "a-1",
		`"é{"#"}#"`:                            "é##",
		`"{"a" |> upper}"`:                     "A",
		`"{"abc" |> substr(1, 1) |> upper}"`:   "B",
		`"{[10, 20, 30][-1]} {"xyz"[1]}"`:      "30 y",
		`(1 |> str) ~ "x"`:                     "1x",
		`"{len("a{{b")}"`:                      "3",
	}
	for expr, want := range cases {
		if got := val(t, expr); got != want {
			t.Errorf("%s = %q, want %q", expr, got, want)
		}
	}
}

func TestExpressionErrors(t *testing.T) {
	cases := map[string]string{
		`"a" + [1]`:                  "E_TYPE operator +: expected int, got str",
		`1 + "a"`:                    "E_TYPE operator +: expected int, got str",
		`-"a"`:                       "E_TYPE operator -: expected int, got str",
		`!1`:                         "E_TYPE operator !: expected bool, got int",
		`true && 1`:                  "E_TYPE operator &&: expected bool, got int",
		`1 || true`:                  "E_TYPE operator ||: expected bool, got int",
		`1 / 0`:                      "E_DIV_ZERO",
		`1 % 0`:                      "E_DIV_ZERO",
		`5["a"]`:                     "E_TYPE index: expected int, got str",
		`5[0]`:                       "E_TYPE index target: expected str|list, got int",
		`[1][1]`:                     "E_ARG fn index: out of range",
		`[1][-2]`:                    "E_ARG fn index: out of range",
		`"{[1]}"`:                    "E_INTERP list",
		`nope(undefined)`:            "E_UNKNOWN_FUNC nope",
		`upper(undefined, 2)`:        "E_UNKNOWN_VAR undefined",
		`upper("a", "b")`:            "E_ARITY fn upper: expected 1, got 2",
		`pathjoin()`:                 "E_ARITY fn pathjoin: expected 1-8, got 0",
		`upper(1)`:                   "E_TYPE fn upper argument 1: expected str, got int",
		`len(1)`:                     "E_TYPE fn len argument 1: expected str|list, got int",
		`str([])`:                    "E_TYPE fn str argument 1: expected str|int|bool, got list",
		`1 |> cost`:                  "E_UNKNOWN_FUNC cost",
		`join([[1]], ",")`:           "E_TYPE fn join element 0: expected str|int, got list",
		`x`:                          "E_UNKNOWN_VAR x",
		`filter([1], "")`:            "E_ARG fn filter: bad pattern",
		`filter([1], "*")`:           "E_TYPE fn filter element 0: expected str, got int",
		`sum([1, "a"])`:              "E_TYPE fn sum element 1: expected int, got str",
		`map([1], "%")`:              "E_TYPE fn map element 0: expected str, got int",
		`glob("a//b")`:               "E_ARG fn glob: bad pattern",
		`first([])`:                  "E_ARG fn first: empty list",
		`range(-1)`:                  "E_ARG fn range: negative",
		`int("1 ")`:                  "E_ARG fn int: bad integer",
		`int("9223372036854775808")`: "E_ARG fn int: bad integer",
		`replace("a", "", "b")`:      "E_ARG fn replace: empty pattern",
		`split("a", "")`:             "E_ARG fn split: empty separator",
	}
	for expr, want := range cases {
		if got := val(t, expr); got != want {
			t.Errorf("%s: got %q, want %q", expr, got, want)
		}
	}
}

func TestBuiltins(t *testing.T) {
	cases := map[string]string{
		`str(len("abc")) ~ str(count([1, 2]))`:                                       "32",
		`upper("aé") ~ lower("ABÉ")`:                                                 "AéabÉ",
		`"[" ~ trim(" \t\r\nx y\n ") ~ "]"`:                                          "[x y]",
		`replace("aaa", "aa", "b")`:                                                  "ba",
		`"{starts_with("abc", "")} {ends_with("abc", "bc")} {contains("abc", "d")}"`: "true true false",
		`substr("abcdef", 1, 3) ~ "," ~ substr("abcdef", -2, 5) ~ "," ~ substr("abcdef", 10, 2) ~ "," ~ substr("abcdef", 2, -1)`: "bcd,ef,,",
		`join(split("a,,b", ","), "|")`: "a||b",
		`"{count(split("", ","))}"`:     "1",
		`"{int("-007")} {int(5)}"`:      "-7 5",
		`dirname("a/b/c") ~ "|" ~ dirname("c") ~ "|" ~ basename("a/b/c") ~ "|" ~ basename("c")`:                                    "a/b||c|c",
		`stem("src/a.b.txt") ~ ext("src/a.b.txt") ~ stem("src/.hidden") ~ "|" ~ ext("src/.hidden") ~ "|" ~ ext("x.") ~ stem("x.")`: "a.b.txt.hidden||.x",
		`pathjoin("out", "", "a.txt") ~ " " ~ pathjoin("out/")`:                                                                    "out/a.txt out/",
		`join(map(["a", "b"], "out/%.o"), " ")`:                                                                                    "out/a.o out/b.o",
		`join(map(["a"], "100%%-%"), "")`:                                                                                          "100%-a",
		`join(filter(["a.c", "b.h", "d/e.c"], "*.c"), ",")`:                                                                        "a.c",
		`join(reject(["a.c", "b.h", "d/e.c"], "**/*.c"), ",")`:                                                                     "b.h",
		`join(sort([3, 1, 2]), "")`:                                                                                                "123",
		`"{sort(["b", 2, true, "a"]) == [true, 2, "a", "b"]}"`:                                                                     "true",
		`"{uniq([1, "1", 1, [1], [1]]) == [1, "1", [1]]}"`:                                                                         "true",
		`join(reverse([1, 2, 3]), "")`:                                                                                             "321",
		`"{first([4, 5])} {last([4, 5])}"`:                                                                                         "4 5",
		`"{slice([1, 2, 3, 4], -3, 2) == [2, 3]}"`:                                                                                 "true",
		`"{has([[1]], [1])} {indexof(["a", "b"], "b")} {indexof([], 1)}"`:                                                          "true 1 -1",
		`"{range(3) == [0, 1, 2]} {range(0) == []}"`:                                                                               "true true",
		`"{sum([])} {sum([1, 2, 3])}"`:                                                                                             "0 6",
		`"{flatten([1, [2, [3]], []]) == [1, 2, [3]]}"`:                                                                            "true",
		`"{zip([1, 2, 3], ["a", "b"]) == [[1, "a"], [2, "b"]]}"`:                                                                   "true",
		`"{is_str("")} {is_int(1)} {is_bool(false)} {is_list([])} {is_int("1")}"`:                                                  "true true true true false",
	}
	for expr, want := range cases {
		if got := val(t, expr); got != want {
			t.Errorf("%s: got %q, want %q", expr, got, want)
		}
	}
	if len(kbl.BuiltinNames()) != 39 {
		t.Errorf("have %d builtins, want 39", len(kbl.BuiltinNames()))
	}
}

func TestGlobBuiltin(t *testing.T) {
	fs := vfs.New()
	for _, p := range []string{"src/b.txt", "src/a.txt", "src/sub/c.txt", "src/n.md", "out/x.txt", ".kiln-state"} {
		fs.Write(p, nil)
	}
	fs.Write("main.kiln", []byte("step {\n out \"out/l\"\n cmd write(join(glob(\"**/*.txt\"), \",\") ~ \"|\" ~ join(glob(\"src/**\"), \",\"))\n}\n"))
	p, err := kbl.Evaluate(fs)
	if err != nil {
		t.Fatal(err)
	}
	want := "src/a.txt,src/b.txt,src/sub/c.txt|src/a.txt,src/b.txt,src/n.md,src/sub/c.txt"
	if got := p.Steps[0].Args[0].Str; got != want {
		t.Errorf("got %q", got)
	}
}

func TestStatements(t *testing.T) {
	src := `
let mode = "fast"
include "tune.kiln"
when mode == "fast" {
    abort "no"
} elsewhen extra == 1 {
    let inner = 5
    phony p = "out/a"
} otherwise {
    abort "no"
}
each i, n in ["a", "b"] {
    step {
        out "out/{n}"
        cmd write("{i}")
    }
}
default ["out/a"]
default "out/b"
`
	p, e := eval(t, src, "tune.kiln", "set mode = \"slow\"\nlet extra = 1\n")
	if e != "" {
		t.Fatal(e)
	}
	if len(p.Steps) != 2 || p.Steps[1].Serial != 1 || p.Steps[1].Outs[0] != "out/b" {
		t.Errorf("steps = %+v", p.Steps)
	}
	if len(p.Phonies) != 1 || p.Phonies[0].Name != "p" {
		t.Errorf("phonies = %+v", p.Phonies)
	}
	if strings.Join(p.Defaults, ",") != "out/a,out/b" {
		t.Errorf("defaults = %v", p.Defaults)
	}
}

func TestRules(t *testing.T) {
	src := `
let base = "out"
rule mk(name, weight = 2, dir = base) {
    step {
        out "{dir}/{name}"
        cmd write(name)
        cost weight
    }
}
use mk("a")
use mk("b", dir = "out/sub", weight = 7)
set base = "out/late"
use mk("c")
`
	p, e := eval(t, src)
	if e != "" {
		t.Fatal(e)
	}
	var outs []string
	for _, s := range p.Steps {
		outs = append(outs, s.Outs[0])
	}
	if strings.Join(outs, ",") != "out/a,out/sub/b,out/late/c" {
		t.Errorf("outs = %v", outs)
	}
	if p.Steps[0].Cost != 2 || p.Steps[1].Cost != 7 {
		t.Error("costs")
	}
}

func TestEvaluationErrors(t *testing.T) {
	step := "step {\n out \"out/a\"\n cmd write(\"x\")\n}\n"
	cases := []struct {
		name, src, want string
		extra           []string
	}{
		{"redefine", "let a = 1\nlet a = 2\n", "E_REDEFINE a", nil},
		{"redefine rhs first", "let a = 1\nlet a = nope\n", "E_UNKNOWN_VAR nope", nil},
		{"shadow ok", "let a = 1\nwhen true {\n let a = 2\n}\n", "", nil},
		{"set undefined", "set a = 1\n", "E_SET_UNDEFINED a", nil},
		{"include missing", "include \"x.kiln\"\n", "E_INCLUDE_MISSING x.kiln", nil},
		{"include bad path", "include \"../x\"\n", "E_BAD_PATH ../x", nil},
		{"include type", "include 1\n", "E_TYPE include path: expected str, got int", nil},
		{"include cycle", "include \"a.kiln\"\n", "E_INCLUDE_CYCLE main.kiln", []string{"a.kiln", "include \"main.kiln\"\n"}},
		{"include twice", "include \"a.kiln\"\ninclude \"a.kiln\"\n", "E_REDEFINE x", []string{"a.kiln", "let x = 1\n"}},
		{"include parse error", "include \"a.kiln\"\n", "E_PARSE a.kiln:2", []string{"a.kiln", "let x = 1\nlet = 2\n"}},
		{"when type", "when 1 {\n}\n", "E_TYPE when condition: expected bool, got int", nil},
		{"each type", "each x in 1 {\n}\n", "E_TYPE each subject: expected list, got int", nil},
		{"unknown rule", "use nope(undefined)\n", "E_UNKNOWN_RULE nope", nil},
		{"rule redefine", "rule r() {\n}\nrule r() {\n}\n", "E_REDEFINE r", nil},
		{"rule arity", "rule r(a) {\n}\nuse r(1, 2)\n", "E_ARITY rule r: expected 1, got 2", nil},
		{"rule unknown kw", "rule r(a) {\n}\nuse r(b = 1)\n", "E_ARG rule r: unknown argument b", nil},
		{"rule duplicate kw", "rule r(a) {\n}\nuse r(1, a = 1)\n", "E_ARG rule r: duplicate argument a", nil},
		{"rule missing", "rule r(a, b) {\n}\nuse r(1)\n", "E_ARG rule r: missing argument b", nil},
		{"rule recursion", "rule r() {\n use r()\n}\nuse r()\n", "E_RULE_RECURSION r", nil},
		{"dup phony", "phony a = []\nphony a = []\n", "E_DUP_PHONY a", nil},
		{"phony bad dep", "phony a = [\"@1x\"]\n", "E_BAD_PATH @1x", nil},
		{"phony type", "phony a = 1\n", "E_TYPE phony a: expected strlist, got int", nil},
		{"default type", "default [\"a\", 1]\n", "E_TYPE default: expected strlist, got int", nil},
		{"abort", "abort \"x{1}\"\n", "E_ABORT x1", nil},
		{"abort type", "abort 1\n", "E_TYPE abort message: expected str, got int", nil},
		{"missing out", "step {\n cmd write(\"x\")\n}\n", "E_STEP_FIELD missing out", nil},
		{"missing cmd", "step {\n out \"out/a\"\n}\n", "E_STEP_FIELD missing cmd", nil},
		{"dup cmd", "step {\n cmd write(\"x\")\n cmd write(nope)\n}\n", "E_STEP_FIELD duplicate cmd", nil},
		{"dup cost", "step {\n cost 1\n cost nope\n}\n", "E_STEP_FIELD duplicate cost", nil},
		{"dup depfile", "step {\n depfile \"out/d\"\n depfile 1\n}\n", "E_STEP_FIELD duplicate depfile", nil},
		{"negative cost", "step {\n cost 0 - 1\n}\n", "E_ARG field cost: negative", nil},
		{"cost type", "step {\n cost \"a\"\n}\n", "E_TYPE field cost: expected int, got str", nil},
		{"out type", "step {\n out [1]\n}\n", "E_TYPE field out: expected strlist, got int", nil},
		{"unknown cmd", "step {\n out \"out/a\"\n cmd nope(undefined)\n}\n", "E_UNKNOWN_CMD nope", nil},
		{"cmd arity", "step {\n out \"out/a\"\n cmd grep()\n}\n", "E_ARITY cmd grep: expected 1, got 0", nil},
		{"cmd type", "step {\n out \"out/a\"\n cmd indent(\"x\")\n}\n", "E_TYPE cmd indent argument 1: expected int, got str", nil},
		{"output path", "step {\n out \"src/a\"\n cmd write(\"\")\n}\n", "E_OUTPUT_PATH src/a", nil},
		{"bad out path", "step {\n out [\"out/a\", \"out/../b\"]\n cmd write(\"\")\n}\n", "E_BAD_PATH out/../b", nil},
		{"bad in", "step {\n out \"out/a\"\n in \"a b\"\n cmd copy()\n}\n", "E_BAD_PATH a b", nil},
		{"shape inputs", "step {\n out \"out/a\"\n cmd copy()\n}\n", "E_CMD_SHAPE copy: expected inputs 1-1, got 0", nil},
		{"shape inputs N", "step {\n out \"out/a\"\n cmd concat()\n}\n", "E_CMD_SHAPE concat: expected inputs 1-N, got 0", nil},
		{"shape write", "step {\n out \"out/a\"\n in \"x\"\n cmd write(\"\")\n}\n", "E_CMD_SHAPE write: expected inputs 0-0, got 1", nil},
		{"phony input not counted", "step {\n out \"out/a\"\n in \"@p\"\n cmd write(\"\")\n}\n", "", nil},
		{"shape outputs", "step {\n out [\"out/a\", \"out/b\"]\n cmd write(\"\")\n}\n", "E_CMD_SHAPE write: expected outputs 1, got 2", nil},
		{"depfile not allowed", "step {\n out \"out/a\"\n depfile \"out/d\"\n cmd write(\"\")\n}\n", "E_CMD_SHAPE write: depfile not allowed", nil},
		{"depfile required", "step {\n out \"out/a\"\n in \"x\"\n cmd preprocess()\n}\n", "E_CMD_SHAPE preprocess: depfile required", nil},
		{"replace empty", "step {\n out \"out/a\"\n in \"x\"\n cmd replace(\"\", \"\")\n}\n", "E_ARG cmd replace: empty pattern", nil},
		{"indent negative", "step {\n out \"out/a\"\n in \"x\"\n cmd indent(0 - 1)\n}\n", "E_ARG cmd indent: negative", nil},
		{"fine", step, "", nil},
	}
	for _, tc := range cases {
		_, got := eval(t, tc.src, tc.extra...)
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestMissingBuildFile(t *testing.T) {
	_, err := kbl.Evaluate(vfs.New())
	if err == nil || err.Error() != "E_NO_BUILD_FILE main.kiln" {
		t.Errorf("got %v", err)
	}
}

func TestParseErrors(t *testing.T) {
	cases := []struct {
		name, src, want string
	}{
		{"ok", "let a = 1\n", ""},
		{"empty", "", ""},
		{"comment only", "# hi\n\n  # there\n", ""},
		{"let reserved", "let in = 1\n", "E_PARSE main.kiln:1"},
		{"var reserved", "let a = step\n", "E_PARSE main.kiln:1"},
		{"reserved call", "let a = step(1)\n", ""},
		{"lexical beats grammar", "let = 1\nlet x = \"abc\n", "E_PARSE main.kiln:2"},
		{"unterminated multi-line", "let b = f(\n  \"unterminated\n)\n", "E_PARSE main.kiln:1"},
		{"unclosed bracket", "\nlet a = [1,\n2\n", "E_PARSE main.kiln:2"},
		{"negative depth", "let a = 1)\n", "E_PARSE main.kiln:1"},
		{"bare pipe", "let a = 1 | 2\n", "E_PARSE main.kiln:1"},
		{"bare amp", "let a = 1 & 2\n", "E_PARSE main.kiln:1"},
		{"bad byte", "let a = 1 @ 2\n", "E_PARSE main.kiln:1"},
		{"comment in string", "let a = \"#x\" # real\n", ""},
		{"comment hides quote", "let a = 1 # \"\n", ""},
		{"multi-line list", "let a = [\n 1, # one\n 2,\n]\n", ""},
		{"bad escape", "let a = \"\\q\"\n", "E_PARSE main.kiln:1"},
		{"lone brace", "let a = \"}\"\n", "E_PARSE main.kiln:1"},
		{"empty interpolation", "let a = \"{ }\"\n", "E_PARSE main.kiln:1"},
		{"bad interpolation", "let a = \"{1 +}\"\n", "E_PARSE main.kiln:1"},
		{"nested literal in interpolation", "let a = \"{\"x\"}\"\n", ""},
		{"trailing tokens", "let a = 1 2\n", "E_PARSE main.kiln:1"},
		{"step field outside", "out \"x\"\n", "E_PARSE main.kiln:1"},
		{"statement in step", "step {\n let a = 1\n}\n", "E_PARSE main.kiln:2"},
		{"block in step", "step {\n when true {\n }\n}\n", "E_PARSE main.kiln:2"},
		{"unterminated block", "let a = 1\nwhen true {\n  each x in [] {\n  }\n", "E_PARSE main.kiln:2"},
		{"unterminated innermost", "when true {\n each x in [] {\n", "E_PARSE main.kiln:2"},
		{"unterminated elsewhen", "when true {\n} elsewhen true {\n", "E_PARSE main.kiln:2"},
		{"stray terminator", "let a = 1\n}\n", "E_PARSE main.kiln:2"},
		{"elsewhen on each", "each x in [] {\n} elsewhen true {\n}\n", "E_PARSE main.kiln:2"},
		{"elsewhen after otherwise", "when true {\n} otherwise {\n} elsewhen true {\n}\n", "E_PARSE main.kiln:3"},
		{"two otherwise", "when true {\n} otherwise {\n} otherwise {\n}\n", "E_PARSE main.kiln:3"},
		{"terminator junk", "when true {\n} foo\n", "E_PARSE main.kiln:2"},
		{"lone open brace", "{\n", "E_PARSE main.kiln:1"},
		{"brace mid-line", "let a = { 1 }\n", "E_PARSE main.kiln:1"},
		{"each same names", "each a, a in [] {\n}\n", "E_PARSE main.kiln:1"},
		{"rule dup param", "rule r(a, a) {\n}\n", "E_PARSE main.kiln:1"},
		{"rule default order", "rule r(a = 1, b) {\n}\n", "E_PARSE main.kiln:1"},
		{"rule reserved param", "rule r(cost) {\n}\n", "E_PARSE main.kiln:1"},
		{"use positional after kw", "use r(a = 1, 2)\n", "E_PARSE main.kiln:1"},
		{"use trailing comma", "use r(1, a = 2,)\n", ""},
		{"call on non-ident", "let a = (f)(1)\n", "E_PARSE main.kiln:1"},
		{"chained call", "let a = f(1)(2)\n", "E_PARSE main.kiln:1"},
		{"pipe target non-ident", "let a = 1 |> 2\n", "E_PARSE main.kiln:1"},
		{"line numbers", "\n\n# c\nlet a = (\n1\n2)\nlet = 1\n", "E_PARSE main.kiln:4"},
		{"cmd with reserved name", "step {\n cmd in()\n}\n", ""},
		{"empty cmd args trailing comma", "step {\n cmd write(\"a\",)\n}\n", ""},
	}
	for _, tc := range cases {
		fs := vfs.New()
		fs.Write("main.kiln", []byte(tc.src))
		got := ""
		if err := kbl.ParseFile("main.kiln", tc.src); err != nil {
			got = err.Error()
		}
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestValueOrdering(t *testing.T) {
	order := []kbl.Value{
		kbl.Bool(false), kbl.Bool(true), kbl.Int(-5), kbl.Int(3), kbl.Str(""), kbl.Str("a"), kbl.Str("ab"), kbl.Str("b"),
		kbl.List(nil), kbl.List([]kbl.Value{kbl.Int(1)}), kbl.List([]kbl.Value{kbl.Int(1), kbl.Int(0)}), kbl.List([]kbl.Value{kbl.Int(2)}),
	}
	for i, a := range order {
		for j, b := range order {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := kbl.Compare(a, b); got != want {
				t.Errorf("Compare(%d, %d) = %d, want %d", i, j, got, want)
			}
		}
	}
	if !kbl.Equal(kbl.List([]kbl.Value{kbl.Str("x")}), kbl.List([]kbl.Value{kbl.Str("x")})) || kbl.Equal(kbl.Int(1), kbl.Bool(true)) {
		t.Error("Equal")
	}
}
