package cmds

import (
	"testing"

	"buildsys/kerr"
	"buildsys/vfs"
)

func TestInvocationString(t *testing.T) {
	tests := []struct {
		inv  Invocation
		want string
	}{
		{Invocation{Name: "concat"}, "concat()"},
		{Invocation{Name: "write", Args: []Arg{{Kind: StrArg, Str: "hello\n"}}}, `write("hello\n")`},
		{Invocation{Name: "replace", Args: []Arg{{Str: `a\b`}, {Str: `"q"`}}}, `replace("a\\b", "\"q\"")`},
		{Invocation{Name: "indent", Args: []Arg{{Kind: IntArg, Int: 4}}}, "indent(4)"},
		{Invocation{Name: "indent", Args: []Arg{{Kind: IntArg, Int: -4}}}, "indent(-4)"},
		{Invocation{Name: "write", Args: []Arg{{Str: "\t\r\x00\x7fü"}}}, `write("\t\r\x00\x7fü")`},
	}
	for _, tc := range tests {
		if got := tc.inv.String(); got != tc.want {
			t.Errorf("got %s, want %s", got, tc.want)
		}
	}
}

func TestSplitJoinLines(t *testing.T) {
	cases := map[string][]string{
		"":         nil,
		"\n":       {""},
		"a\nb\n":   {"a", "b"},
		"a\nb":     {"a", "b"},
		"a\n\nb\n": {"a", "", "b"},
		"a\r\n":    {"a\r"},
	}
	for in, want := range cases {
		got := SplitLines(in)
		if len(got) != len(want) {
			t.Errorf("SplitLines(%q) = %q, want %q", in, got, want)
			continue
		}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("SplitLines(%q) = %q, want %q", in, got, want)
			}
		}
	}
	if got := JoinLines([]string{"a", ""}); got != "a\n\n" {
		t.Errorf("JoinLines = %q", got)
	}
}

func run(t *testing.T, name string, args []Arg, files ...string) string {
	t.Helper()
	spec, ok := Lookup(name)
	if !ok {
		t.Fatalf("no command %s", name)
	}
	var in []Input
	for i, c := range files {
		in = append(in, Input{Path: "in" + string(rune('0'+i)), File: vfs.NewFile(c)})
	}
	res, err := spec.Run(Invocation{Name: name, Args: args}, in, vfs.New())
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return res.Output
}

func TestCommands(t *testing.T) {
	s := func(v string) Arg { return Arg{Kind: StrArg, Str: v} }
	tests := []struct {
		name  string
		args  []Arg
		files []string
		want  string
	}{
		{"write", []Arg{s("x\n")}, nil, "x\n"},
		{"copy", nil, []string{"a\nb"}, "a\nb"},
		{"concat", nil, []string{"a", "b", "a"}, "aba"},
		{"upper", nil, []string{"aB1é"}, "AB1é"},
		{"lower", nil, []string{"aB1É"}, "ab1É"},
		{"grep", []Arg{s("b")}, []string{"ab\ncd\nb"}, "ab\nb\n"},
		{"grep", []Arg{s("")}, []string{"x\ny"}, "x\ny\n"},
		{"replace", []Arg{s("aa"), s("b")}, []string{"aaaaa"}, "bba"},
		{"sort_lines", nil, []string{"b\na\nB\n"}, "B\na\nb\n"},
		{"reverse_lines", nil, []string{"a\nb\nc"}, "c\nb\na\n"},
		{"dedup", nil, []string{"a\nb\na\nb\nc"}, "a\nb\nc\n"},
		{"number", nil, []string{"a\nb\nc\n"}, "1: a\n2: b\n3: c\n"},
		{"indent", []Arg{{Kind: IntArg, Int: 2}}, []string{"a\n\nb"}, "  a\n  \n  b\n"},
		{"wrap", []Arg{s("<"), s(">")}, []string{"x"}, "<x>"},
		{"count_lines", nil, []string{"a\nb\n", ""}, "2 in0\n0 in1\n2 total\n"},
		{"hash", nil, []string{"hello\n", "hello\n"}, "a9bc80cca21f28b3 in0\na9bc80cca21f28b3 in1\n"},
	}
	for _, tc := range tests {
		if got := run(t, tc.name, tc.args, tc.files...); got != tc.want {
			t.Errorf("%s(%v) = %q, want %q", tc.name, tc.args, got, tc.want)
		}
	}
}

func TestPreprocess(t *testing.T) {
	fs := vfs.New()
	fs.Write("src/part.txt", "PART\n@need src/deep.txt\n")
	fs.Write("src/deep.txt", "DEEP\n")
	fs.Write("src/loop.txt", "@need src/loop2.txt\n")
	fs.Write("src/loop2.txt", "@need src/loop.txt\n")
	spec, _ := Lookup("preprocess")
	runIt := func(main string) (Result, *kerr.Error) {
		return spec.Run(Invocation{Name: "preprocess"}, []Input{{Path: "src/main.txt", File: vfs.NewFile(main)}}, fs)
	}

	res, err := runIt("title\n@need src/part.txt\n@need src/deep.txt\nend\n")
	if err != nil {
		t.Fatal(err)
	}
	if want := "title\nPART\nDEEP\nDEEP\nend\n"; res.Output != want {
		t.Errorf("output = %q, want %q", res.Output, want)
	}
	if want := "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n"; res.Depfile != want {
		t.Errorf("depfile = %q, want %q", res.Depfile, want)
	}

	cases := []struct{ main, kind, detail string }{
		{"@need bad path\n", kerr.NeedPath, "bad path"},
		{"@need src/none.txt\n", kerr.NeedMissing, "src/none.txt needed by src/main.txt"},
		{"@need src/loop.txt\n", kerr.NeedCycle, "src/loop.txt"},
		{"@need src/main.txt\n", kerr.NeedCycle, "src/main.txt"},
	}
	fs.Write("src/main.txt", "@need src/main.txt\n")
	for _, tc := range cases {
		_, err := runIt(tc.main)
		if err == nil || err.Kind != tc.kind || err.Detail != tc.detail {
			t.Errorf("%q: got %v, want %s %s", tc.main, err, tc.kind, tc.detail)
		}
	}
	// "@need" with no argument is an ordinary line.
	if res, err := runIt("@need \n@needx\n"); err != nil || res.Output != "@need \n@needx\n" {
		t.Errorf("non-directives: %q %v", res.Output, err)
	}
}

func TestSpecChecks(t *testing.T) {
	spec, _ := Lookup("replace")
	if err := spec.CheckArgs(Invocation{Name: "replace", Args: []Arg{{Str: ""}, {Str: "x"}}}); err == nil {
		t.Error("empty replace pattern accepted")
	}
	spec, _ = Lookup("indent")
	if err := spec.CheckArgs(Invocation{Name: "indent", Args: []Arg{{Kind: IntArg, Int: -1}}}); err == nil {
		t.Error("negative indent accepted")
	}
	if len(Names()) != 16 {
		t.Errorf("want 16 commands, got %d", len(Names()))
	}
	c, _ := Lookup("concat")
	if c.InputRange() != "1-N" {
		t.Errorf("concat range = %s", c.InputRange())
	}
}
