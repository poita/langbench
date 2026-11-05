package command_test

import (
	"testing"

	"buildsys/command"
	"buildsys/vfs"
)

type files map[string]string

func (f files) Read(p string) ([]byte, bool) {
	s, ok := f[p]
	return []byte(s), ok
}

func in(path, content string) command.Input {
	return command.Input{Path: path, Content: []byte(content), Hash: vfs.Hash64([]byte(content))}
}

func run(t *testing.T, name string, args []command.Arg, inputs ...command.Input) string {
	t.Helper()
	res, err := command.Run(name, args, inputs, files{})
	if err != nil {
		t.Fatalf("%s: unexpected error %v", name, err)
	}
	return string(res.Out)
}

func TestSimpleCommands(t *testing.T) {
	s, i := command.StrOf, command.IntOf
	cases := []struct {
		name   string
		args   []command.Arg
		inputs []command.Input
		want   string
	}{
		{"write", []command.Arg{s("hi\x00")}, nil, "hi\x00"},
		{"copy", nil, []command.Input{in("a", "x\ny")}, "x\ny"},
		{"concat", nil, []command.Input{in("a", "1"), in("b", "2"), in("a", "1")}, "121"},
		{"upper", nil, []command.Input{in("a", "aBc é\n")}, "ABC é\n"},
		{"lower", nil, []command.Input{in("a", "aBc É\n")}, "abc É\n"},
		{"grep", []command.Arg{s("b")}, []command.Input{in("a", "abc\nxyz\nb")}, "abc\nb\n"},
		{"grep", []command.Arg{s("")}, []command.Input{in("a", "a\n\nb")}, "a\n\nb\n"},
		{"replace", []command.Arg{s("aa"), s("b")}, []command.Input{in("a", "aaa\naa")}, "ba\nb"},
		{"sort_lines", nil, []command.Input{in("a", "b\na\nc\na")}, "a\na\nb\nc\n"},
		{"reverse_lines", nil, []command.Input{in("a", "1\n2\n3")}, "3\n2\n1\n"},
		{"dedup", nil, []command.Input{in("a", "a\nb\na\n\n\nb\n")}, "a\nb\n\n"},
		{"number", nil, []command.Input{in("a", "a\n\nc\n")}, "1: a\n2: \n3: c\n"},
		{"indent", []command.Arg{i(2)}, []command.Input{in("a", "a\n\nb")}, "  a\n  \n  b\n"},
		{"wrap", []command.Arg{s("<"), s(">")}, []command.Input{in("a", "mid")}, "<mid>"},
		{"count_lines", nil, []command.Input{in("a", "1\n2\n"), in("b", ""), in("c", "x")}, "2 a\n0 b\n1 c\n3 total\n"},
		{"hash", nil, []command.Input{in("a", "hello\n"), in("a", "hello\n")}, "a9bc80cca21f28b3 a\na9bc80cca21f28b3 a\n"},
	}
	for _, tc := range cases {
		if got := run(t, tc.name, tc.args, tc.inputs...); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestReplaceAndCountLines(t *testing.T) {
	if got := string(command.Replace([]byte("aaaa"), []byte("aa"), []byte("b"))); got != "bb" {
		t.Errorf("Replace = %q", got)
	}
	for in, want := range map[string]int{"": 0, "\n": 1, "a": 1, "a\n": 1, "a\nb": 2, "a\n\nb\n": 3} {
		if got := command.CountLines([]byte(in)); got != want {
			t.Errorf("CountLines(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestPreprocess(t *testing.T) {
	fs := files{
		"b.txt": "B1\n@need c.txt\nB2",
		"c.txt": "C\n",
		"d.txt": "@need b.txt\n",
	}
	res, err := command.Run("preprocess", nil, []command.Input{in("a.txt", "A\n@need b.txt\n@need c.txt\n@need  x\n")}, fs)
	if err == nil || err.Kind != "E_NEED_PATH" || err.Detail != " x" {
		t.Fatalf("want E_NEED_PATH ' x', got %v", err)
	}
	res, err = command.Run("preprocess", nil, []command.Input{in("a.txt", "A\n@need b.txt\n@need c.txt\n@needx\n@need\n")}, fs)
	if err != nil {
		t.Fatal(err)
	}
	if string(res.Out) != "A\nB1\nC\nB2\nC\n@needx\n@need\n" {
		t.Errorf("out = %q", res.Out)
	}
	if string(res.Depfile) != "kiln-deps 1\nneed b.txt\nneed c.txt\n" {
		t.Errorf("depfile = %q", res.Depfile)
	}
	if len(res.Deps) != 2 {
		t.Errorf("deps = %v", res.Deps)
	}

	res, err = command.Run("preprocess", nil, []command.Input{in("a.txt", "plain\n")}, fs)
	if err != nil || string(res.Depfile) != "kiln-deps 1\n" {
		t.Errorf("empty discovered set: %q %v", res.Depfile, err)
	}

	_, err = command.Run("preprocess", nil, []command.Input{in("a.txt", "@need nope.txt\n")}, fs)
	if err == nil || err.Error() != "E_NEED_MISSING nope.txt needed by a.txt" {
		t.Errorf("missing: %v", err)
	}
	_, err = command.Run("preprocess", nil, []command.Input{in("d.txt", "@need b.txt\n@need d.txt\n")}, fs)
	if err == nil || err.Error() != "E_NEED_CYCLE d.txt" {
		t.Errorf("cycle: %v", err)
	}
}

func TestCanonical(t *testing.T) {
	cases := []struct {
		name string
		args []command.Arg
		want string
	}{
		{"concat", nil, "concat()"},
		{"write", []command.Arg{command.StrOf("hello\n")}, `write("hello\n")`},
		{"replace", []command.Arg{command.StrOf(`a\b`), command.StrOf(`"c"`)}, `replace("a\\b", "\"c\"")`},
		{"indent", []command.Arg{command.IntOf(-4)}, "indent(-4)"},
		{"write", []command.Arg{command.StrOf("\t\r\x00\x1f\x7f é")}, `write("\t\r\x00\x1f\x7f é")`},
		{"wrap", []command.Arg{command.StrOf("<<"), command.StrOf(">>")}, `wrap("<<", ">>")`},
	}
	for _, tc := range cases {
		if got := command.Canonical(tc.name, tc.args); got != tc.want {
			t.Errorf("Canonical = %s, want %s", got, tc.want)
		}
	}
}

func TestSpecs(t *testing.T) {
	for _, name := range []string{"write", "copy", "concat", "upper", "lower", "grep", "replace", "sort_lines",
		"reverse_lines", "dedup", "number", "indent", "wrap", "count_lines", "hash", "preprocess"} {
		if _, ok := command.Lookup(name); !ok {
			t.Errorf("missing command %s", name)
		}
	}
	if _, ok := command.Lookup("nope"); ok {
		t.Error("unknown command found")
	}
	c, _ := command.Lookup("concat")
	if c.InputRange() != "1-N" || !c.FitsInputs(3) || c.FitsInputs(0) {
		t.Error("concat shape")
	}
	w, _ := command.Lookup("write")
	if w.InputRange() != "0-0" || w.FitsInputs(1) || w.DefaultCost != 1 {
		t.Error("write shape")
	}
	p, _ := command.Lookup("preprocess")
	if !p.Depfile || p.DefaultCost != 6 {
		t.Error("preprocess shape")
	}
}
