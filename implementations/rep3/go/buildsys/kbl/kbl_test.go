package kbl

import (
	"strings"
	"testing"

	"buildsys/vfs"
)

func workspace(files map[string]string) *vfs.FS {
	fs := vfs.New()
	for p, c := range files {
		fs.Write(p, []byte(c))
	}
	return fs
}

// errOf evaluates main.kiln and returns the error text ("" on success).
func errOf(t *testing.T, src string, extra ...map[string]string) string {
	t.Helper()
	files := map[string]string{"main.kiln": src}
	for _, m := range extra {
		for k, v := range m {
			files[k] = v
		}
	}
	_, err := Evaluate(workspace(files), "main.kiln")
	if err == nil {
		return ""
	}
	return err.Error()
}

// show evaluates an expression and renders it through an abort message.
func show(t *testing.T, expr string) string {
	t.Helper()
	e := errOf(t, "abort \"{"+expr+"}\"")
	if e == "E_ABORT" {
		return ""
	}
	if !strings.HasPrefix(e, "E_ABORT ") {
		return e
	}
	return strings.TrimPrefix(e, "E_ABORT ")
}

func TestExpressions(t *testing.T) {
	cases := []struct{ expr, want string }{
		{`1 + 2 * 3`, "7"},
		{`(1 + 2) * 3`, "9"},
		{`-7 / 2`, "-3"},
		{`-7 % 3`, "-1"},
		{`7 % -3`, "1"},
		{`10 - 3 - 2`, "5"},
		{`"a" ~ "b" ~ "c"`, "abc"},
		{`len([1] ++ [2] ++ [3])`, "3"},
		{`1 < 2 && "a" < "b"`, "true"},
		{`"a" < 1`, "false"},
		{`[1, 2] < [1, 3]`, "true"},
		{`[1] < [1, 0]`, "true"},
		{`true < 0`, "true"},
		{`[1, [2]] == [1, [2]]`, "true"},
		{`1 == "1"`, "false"},
		{`true || nope`, "true"},
		{`false && nope`, "false"},
		{`!false`, "true"},
		{`- -3`, "3"},
		{`"hello"[1]`, "e"},
		{`"hello"[-1]`, "o"},
		{`[1, 2, 3][-3]`, "1"},
		{`["a", "b"] |> join(",")`, "a,b"},
		{`"abc" |> upper |> lower |> len`, "3"},
		{`1 |> str`, "1"},
		{`join(["x", 1, ], "-")`, "x-1"},
		{`"{{x}}"`, "{x}"},
		{`'it''s {x}'`, "it's {x}"},
	}
	for _, c := range cases {
		if got := show(t, c.expr); got != c.want {
			t.Errorf("%s = %q, want %q", c.expr, got, c.want)
		}
	}
}

func TestExpressionErrors(t *testing.T) {
	cases := []struct{ expr, want string }{
		{`"a" + [1]`, "E_TYPE operator +: expected int, got str"},
		{`1 + "a"`, "E_TYPE operator +: expected int, got str"},
		{`1 / 0`, "E_DIV_ZERO"},
		{`1 % 0`, "E_DIV_ZERO"},
		{`!1`, "E_TYPE operator !: expected bool, got int"},
		{`-"a"`, "E_TYPE operator -: expected int, got str"},
		{`1 || true`, "E_TYPE operator ||: expected bool, got int"},
		{`false || 1`, "E_TYPE operator ||: expected bool, got int"},
		{`5["a"]`, "E_TYPE index: expected int, got str"},
		{`5[0]`, "E_TYPE index target: expected str|list, got int"},
		{`[1][1]`, "E_ARG fn index: out of range"},
		{`[1][-2]`, "E_ARG fn index: out of range"},
		{`nope(undefined)`, "E_UNKNOWN_FUNC nope"},
		{`upper(undefined, 2)`, "E_UNKNOWN_VAR undefined"},
		{`upper("a", "b")`, "E_ARITY fn upper: expected 1, got 2"},
		{`pathjoin()`, "E_ARITY fn pathjoin: expected 1-8, got 0"},
		{`upper(1)`, "E_TYPE fn upper argument 1: expected str, got int"},
		{`[1]`, "E_INTERP list"},
		{`cost(1)`, "E_UNKNOWN_FUNC cost"},
		{`1 |> cost`, "E_UNKNOWN_FUNC cost"},
		{`filter([1], "")`, "E_ARG fn filter: bad pattern"},
		{`filter([1], "*")`, "E_TYPE fn filter element 0: expected str, got int"},
		{`join([[1]], ",")`, "E_TYPE fn join element 0: expected str|int, got list"},
		{`sum([1, "a"])`, "E_TYPE fn sum element 1: expected int, got str"},
		{`int("1x")`, "E_ARG fn int: bad integer"},
		{`int("+1")`, "E_ARG fn int: bad integer"},
		{`int("99999999999999999999")`, "E_ARG fn int: bad integer"},
		{`first([])`, "E_ARG fn first: empty list"},
		{`range(-1)`, "E_ARG fn range: negative"},
		{`split("a", "")`, "E_ARG fn split: empty separator"},
		{`replace("a", "", "b")`, "E_ARG fn replace: empty pattern"},
		{`glob("")`, "E_ARG fn glob: bad pattern"},
	}
	for _, c := range cases {
		if got := show(t, c.expr); got != c.want {
			t.Errorf("%s: got %q, want %q", c.expr, got, c.want)
		}
	}
}

func TestBuiltins(t *testing.T) {
	cases := []struct{ expr, want string }{
		{`substr("abcdef", 1, 3)`, "bcd"},
		{`substr("abcdef", -2, 5)`, "ef"},
		{`substr("abcdef", 10, 2)`, ""},
		{`substr("abcdef", 2, -1)`, ""},
		{`join(slice([1, 2, 3, 4], -3, 2), ",")`, "2,3"},
		{`join(split("a,,b", ","), "|")`, "a||b"},
		{`len(split("", ","))`, "1"},
		{`trim("  \t\nx\r ")`, "x"},
		{`replace("aaa", "aa", "b")`, "ba"},
		{`stem("src/a.b.txt") ~ "|" ~ ext("src/a.b.txt")`, "a.b|.txt"},
		{`stem("src/.hidden") ~ "|" ~ ext("src/.hidden")`, ".hidden|"},
		{`stem("src/x.") ~ "|" ~ ext("src/x.")`, "x|."},
		{`dirname("a/b/c") ~ "|" ~ basename("a/b/c") ~ "|" ~ dirname("c")`, "a/b|c|"},
		{`pathjoin("out", "", "a.txt")`, "out/a.txt"},
		{`pathjoin("out/")`, "out/"},
		{`join(map(["a", "b"], "out/%.o"), " ")`, "out/a.o out/b.o"},
		{`join(map(["a"], "100%%-%"), "")`, "100%-a"},
		{`join(sort([3, 1, "b", "a", true, [0]]), ",") `, "E_TYPE fn join element 0: expected str|int, got bool"},
		{`join(sort([3, 1, "b", "a"]), ",")`, "1,3,a,b"},
		{`join(uniq([1, 2, 1, "1", 2]), ",")`, "1,2,1"},
		{`join(reverse([1, 2, 3]), ",")`, "3,2,1"},
		{`last([1, 2, 3])`, "3"},
		{`has([[1], 2], [1])`, "true"},
		{`indexof(["a", "b"], "b")`, "1"},
		{`indexof(["a"], "z")`, "-1"},
		{`sum(range(5))`, "10"},
		{`len(flatten([[1, 2], 3, [[4]]]))`, "4"},
		{`len(zip([1, 2, 3], ["a", "b"]))`, "2"},
		{`str(true) ~ str(-5) ~ str("x")`, "true-5x"},
		{`int("-007") + int(3)`, "-4"},
		{`upper("aé") ~ lower("ÀB")`, "AéÀb"},
		{`is_str("") && is_int(0) && is_bool(false) && is_list([]) && !is_list("")`, "true"},
		{`starts_with("abc", "") && ends_with("abc", "bc") && contains("abc", "")`, "true"},
		{`count([1, 2])`, "2"},
		{`len("héllo")`, "6"},
	}
	for _, c := range cases {
		if got := show(t, c.expr); got != c.want {
			t.Errorf("%s = %q, want %q", c.expr, got, c.want)
		}
	}
}

func TestGlobAndFilter(t *testing.T) {
	files := map[string]string{
		"main.kiln":   `abort join(glob("src/**/*.txt"), ",")`,
		"src/a.txt":   "",
		"src/b.md":    "",
		"src/x/c.txt": "",
		"out/z.txt":   "",
		".kiln-state": "",
	}
	_, err := Evaluate(workspace(files), "main.kiln")
	if err == nil || err.Error() != "E_ABORT src/a.txt,src/x/c.txt" {
		t.Errorf("got %v", err)
	}
	if got := show(t, `join(filter(["a.c", "b.h", "c.c"], "*.c"), ",") ~ "/" ~ join(reject(["a.c", "b.h"], "*.c"), ",")`); got != "a.c,c.c/b.h" {
		t.Errorf("filter/reject: %q", got)
	}
}

func TestParseErrorLines(t *testing.T) {
	cases := []struct {
		src  string
		line int
	}{
		{"let = 1\nlet x = \"abc\n", 2},
		{"let b = f(\n  \"unterminated\n)\n", 1},
		{"let x = 1 +\n", 1},
		{"let x = (1\n", 1},
		{"let x = 1)\n", 1},
		{"\n\nlet x = 1 | 2\n", 3},
		{"let x = 1 & 2\n", 1},
		{"let x = @\n", 1},
		{"step {\n", 1},
		{"when true {\nstep {\n", 2},
		{"when true {\n} elsewhen true {\n", 2},
		{"when true {\n} otherwise {\n", 2},
		{"}\n", 1},
		{"{\n", 1},
		{"when true {\n} otherwise {\n} elsewhen true {\n}\n", 3},
		{"when true {\n} otherwise {\n} otherwise {\n}\n", 3},
		{"rule r() {\n} elsewhen true {\n}\n", 2},
		{"} foo\n", 1},
		{"out \"x\"\n", 1},
		{"step {\nlet x = 1\n}\n", 2},
		{"let x = \"a\\qb\"\n", 1},
		{"let x = \"a}b\"\n", 1},
		{"let x = \"{}\"\n", 1},
		{"let x = \"{ }\"\n", 1},
		{"let x = \"{1 2}\"\n", 1},
		{"let true = 1\n", 1},
		{"let x = f(1)(2)\n", 1},
		{"let x = (f)(2)\n", 1},
		{"each a, a in [] {\n}\n", 1},
		{"each in in [] {\n}\n", 1},
		{"rule r(a, a) {\n}\n", 1},
		{"rule r(a = 1, b) {\n}\n", 1},
		{"rule r(cost) {\n}\n", 1},
		{"use r(a = 1, 2)\n", 1},
		{"let x = 1 2\n", 1},
		{"let x = x |> 3\n", 1},
		{"when true\n", 1},
		{"# comment only\nstep x {\n}\n", 2},
	}
	for _, c := range cases {
		_, err := Parse(c.src)
		se, ok := err.(*SyntaxError)
		if !ok || se.Line != c.line {
			t.Errorf("%q: got %v, want line %d", c.src, err, c.line)
		}
	}
}

func TestParseOK(t *testing.T) {
	good := []string{
		"",
		"# only a comment\n\n   \n",
		"let x = \"a # not a comment\" # comment\n",
		"let x = f(\n 1,\n 2,\n)\n",
		"let s = \"{join([\"a\", \"b\"], \", \")}\"\n",
		"let s = \"{ '}' }\"\n",
		"when true {\n} elsewhen false {\n} otherwise {\n}\n",
		"rule r(a, b = a ~ \"x\", ) {\n step {\n out \"out/x\"\n cmd write(\"\")\n }\n}\n",
		"use r(1, k = 2,)\n",
		"let x = true(1)\n",
		"each i, n in [1] {\n}\n",
		"let x = 1 |> f |> g(1, 2,)\n",
		"let x = [[1], [2]][0][0]\n",
		"let x = (1 +\n 2)\n",
	}
	for _, src := range good {
		if _, err := Parse(src); err != nil {
			t.Errorf("%q: %v", src, err)
		}
	}
}

func TestScopes(t *testing.T) {
	cases := []struct{ src, want string }{
		{"let x = 1\nlet x = 2\n", "E_REDEFINE x"},
		{"let x = 1\nwhen true {\n let x = 2\n set x = 3\n}\nabort str(x)\n", "E_ABORT 1"},
		{"let x = 1\nwhen true {\n set x = 3\n}\nabort str(x)\n", "E_ABORT 3"},
		{"set y = 1\n", "E_SET_UNDEFINED y"},
		{"let x = y\nlet y = 1\n", "E_UNKNOWN_VAR y"},
		{"let x = x\n", "E_UNKNOWN_VAR x"},
		{"each i, v in [10, 20] {\n let t = i\n}\nabort str(i)\n", "E_UNKNOWN_VAR i"},
		{"each v in 5 {\n}\n", "E_TYPE each subject: expected list, got int"},
		{"when 1 {\n}\n", "E_TYPE when condition: expected bool, got int"},
		{"when false {\n} elsewhen 1 {\n}\n", "E_TYPE when condition: expected bool, got int"},
		{"abort 1\n", "E_TYPE abort message: expected str, got int"},
		{"include 1\n", "E_TYPE include path: expected str, got int"},
		{"include \"a b\"\n", "E_BAD_PATH a b"},
		{"include \"nope.kiln\"\n", "E_INCLUDE_MISSING nope.kiln"},
		{"include \"main.kiln\"\n", "E_INCLUDE_CYCLE main.kiln"},
		{"default 1\n", "E_TYPE default: expected strlist, got int"},
		{"default [\"a\", 2]\n", "E_TYPE default: expected strlist, got int"},
		{"phony p = 1\n", "E_TYPE phony p: expected strlist, got int"},
		{"phony p = [\"@bad name\"]\n", "E_BAD_PATH @bad name"},
		{"phony p = []\nphony p = []\n", "E_DUP_PHONY p"},
		{"phony p = []\nphony p = 1\n", "E_TYPE phony p: expected strlist, got int"},
	}
	for _, c := range cases {
		if got := errOf(t, c.src); got != c.want {
			t.Errorf("%q: got %q, want %q", c.src, got, c.want)
		}
	}
}

func TestIncludeRunsInCurrentScope(t *testing.T) {
	inc := map[string]string{"a.kiln": "set mode = \"slow\"\nlet extra = 1\n"}
	if got := errOf(t, "let mode = \"fast\"\ninclude \"a.kiln\"\nabort mode ~ str(extra)\n", inc); got != "E_ABORT slow1" {
		t.Error(got)
	}
	if got := errOf(t, "let mode = \"fast\"\ninclude \"a.kiln\"\ninclude \"a.kiln\"\n", inc); got != "E_REDEFINE extra" {
		t.Error(got)
	}
	if got := errOf(t, "include \"a.kiln\"\n", map[string]string{"a.kiln": "include \"b.kiln\"\n", "b.kiln": "include \"a.kiln\"\n"}); got != "E_INCLUDE_CYCLE a.kiln" {
		t.Error(got)
	}
	if got := errOf(t, "include \"a.kiln\"\n", map[string]string{"a.kiln": "let x = 1\nlet = \n"}); got != "E_PARSE a.kiln:2" {
		t.Error(got)
	}
	if got := errOf(t, "abort \"first\"\nlet = 1\n"); got != "E_PARSE main.kiln:2" {
		t.Error("syntax errors precede runtime errors:", got)
	}
}

func TestRules(t *testing.T) {
	rule := "let base = 10\nrule r(a, b = a + 1) {\n abort \"{a},{b},{base}\"\n}\n"
	cases := []struct{ use, want string }{
		{"use r(1)", "E_ABORT 1,2,10"},
		{"use r(1, 5)", "E_ABORT 1,5,10"},
		{"use r(b = 7, a = 2)", "E_ABORT 2,7,10"},
		{"use r()", "E_ARG rule r: missing argument a"},
		{"use r(1, 2, 3)", "E_ARITY rule r: expected 2, got 3"},
		{"use r(1, a = 2)", "E_ARG rule r: duplicate argument a"},
		{"use r(1, c = 2)", "E_ARG rule r: unknown argument c"},
		{"use nope(undefined)", "E_UNKNOWN_RULE nope"},
	}
	for _, c := range cases {
		if got := errOf(t, rule+c.use+"\n"); got != c.want {
			t.Errorf("%s: got %q, want %q", c.use, got, c.want)
		}
	}
	if got := errOf(t, "rule r() {\n}\nrule r() {\n}\n"); got != "E_REDEFINE r" {
		t.Error(got)
	}
	// Rules see their defining scope by reference.
	if got := errOf(t, "let v = 1\nrule r() {\n abort str(v)\n}\nset v = 2\nuse r()\n"); got != "E_ABORT 2" {
		t.Error(got)
	}
}

func TestRuleRecursionDepth(t *testing.T) {
	src := "rule r(n) {\n when n > 0 {\n  use r(n - 1)\n }\n}\n"
	if got := errOf(t, src+"use r(63)\n"); got != "" {
		t.Errorf("depth 64: %q", got)
	}
	if got := errOf(t, src+"use r(64)\n"); got != "E_RULE_RECURSION r" {
		t.Errorf("depth 65: %q", got)
	}
}

func TestSteps(t *testing.T) {
	step := func(fields string) string {
		return "step {\n" + fields + "\n}\n"
	}
	cases := []struct{ fields, want string }{
		{`cmd write("x")`, "E_STEP_FIELD missing out"},
		{`out "out/a"`, "E_STEP_FIELD missing cmd"},
		{"out \"out/a\"\ncmd write(\"x\")\ncmd write(\"y\")", "E_STEP_FIELD duplicate cmd"},
		{"out \"out/a\"\ncost 1\ncost undefined", "E_STEP_FIELD duplicate cost"},
		{"out \"out/a\"\ndepfile \"out/d\"\ndepfile 1", "E_STEP_FIELD duplicate depfile"},
		{"out \"out/a\"\ncost -1\ncmd write(\"x\")", "E_ARG field cost: negative"},
		{"out \"out/a\"\ncost \"1\"\ncmd write(\"x\")", "E_TYPE field cost: expected int, got str"},
		{"out 1\ncmd write(\"x\")", "E_TYPE field out: expected strlist, got int"},
		{"out [\"out/a\", 1]\ncmd write(\"x\")", "E_TYPE field out: expected strlist, got int"},
		{"out \"out/a\"\ncmd nope()", "E_UNKNOWN_CMD nope"},
		{"out \"out/a\"\ncmd grep()", "E_ARITY cmd grep: expected 1, got 0"},
		{"out \"out/a\"\ncmd write(1)", "E_TYPE cmd write argument 1: expected str, got int"},
		{"out \"out/a\"\ncmd indent(\"x\")", "E_TYPE cmd indent argument 1: expected int, got str"},
		{"out \"src/a\"\ncmd write(\"x\")", "E_OUTPUT_PATH src/a"},
		{"out \"out/a b\"\ncmd write(\"x\")", "E_BAD_PATH out/a b"},
		{"out \"out/a\"\nin \"@x y\"\ncmd write(\"x\")", "E_BAD_PATH @x y"},
		{"out \"out/a\"\ncmd copy()", "E_CMD_SHAPE copy: expected inputs 1-1, got 0"},
		{"out \"out/a\"\ncmd replace(\"\", \"x\")\nin \"main.kiln\"", "E_ARG cmd replace: empty pattern"},
		{"out \"out/a\"\ncmd indent(-1)\nin \"main.kiln\"", "E_ARG cmd indent: negative"},
		{"out [\"out/a\", \"out/b\"]\ncmd write(\"x\")", "E_CMD_SHAPE write: expected outputs 1, got 2"},
		{"out \"out/a\"\nin \"main.kiln\"\ncmd preprocess()", "E_CMD_SHAPE preprocess: depfile required"},
		{"out \"out/a\"\ncmd write(\"x\")\ncost 0", ""},
	}
	for _, c := range cases {
		if got := errOf(t, step(c.fields)); got != c.want {
			t.Errorf("%q: got %q, want %q", c.fields, got, c.want)
		}
	}
}

func TestStepSerialsAndDefaults(t *testing.T) {
	src := `rule w(n) {
    step {
        out "out/{n}"
        cmd write("{n}")
    }
}
each n in ["a", "b"] {
    use w(n)
}
phony all = ["out/a", "out/b"]
default "@all"
default ["out/a"]
`
	b, err := Evaluate(workspace(map[string]string{"main.kiln": src}), "main.kiln")
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Steps) != 2 || b.Steps[0].Serial != 0 || b.Steps[1].Primary() != "out/b" || b.Steps[1].Serial != 1 {
		t.Errorf("steps: %+v", b.Steps)
	}
	if len(b.Defaults) != 2 || b.Defaults[0] != "@all" {
		t.Errorf("defaults %v", b.Defaults)
	}
	if !b.HasPhony("all") {
		t.Error("phony missing")
	}
}

func TestValueOrder(t *testing.T) {
	order := []Value{Bool(false), Bool(true), Int(-1), Int(5), Str(""), Str("a"), Str("ab"), Str("b"), List(), List(Int(1)), List(Int(1), Int(0)), List(Int(2))}
	for i := range order {
		for j := range order {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(order[i], order[j]); got != want {
				t.Errorf("Compare(%d,%d) = %d", i, j, got)
			}
			if Equal(order[i], order[j]) != (i == j) {
				t.Errorf("Equal(%d,%d)", i, j)
			}
		}
	}
}

func TestBuiltinCount(t *testing.T) {
	if n := len(BuiltinNames()); n != 39 {
		t.Errorf("%d builtins, want 39", n)
	}
}
