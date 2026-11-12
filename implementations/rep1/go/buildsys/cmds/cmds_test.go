package cmds

import (
	"reflect"
	"strings"
	"testing"

	"buildsys/kerr"
	"buildsys/vfs"
)

func workspace(files map[string]string) *vfs.FS {
	f := vfs.New()
	for p, c := range files {
		f.Write(p, c)
	}
	return f
}

func run(t *testing.T, name string, args []Arg, inputs []string, fs *vfs.FS) Result {
	t.Helper()
	spec, ok := Lookup(name)
	if !ok {
		t.Fatalf("no command %s", name)
	}
	r, err := Run(spec, args, inputs, fs)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return r
}

func TestCommands(t *testing.T) {
	fs := workspace(map[string]string{
		"a": "b\nA\nb\n\nc",
		"x": "x\n",
		"u": "Hello ü\n",
	})
	tests := []struct {
		name   string
		args   []Arg
		inputs []string
		want   string
	}{
		{"write", []Arg{StrArg("hi")}, nil, "hi"},
		{"copy", nil, []string{"a"}, "b\nA\nb\n\nc"},
		{"concat", nil, []string{"x", "x"}, "x\nx\n"},
		{"upper", nil, []string{"u"}, "HELLO ü\n"},
		{"lower", nil, []string{"u"}, "hello ü\n"},
		{"grep", []Arg{StrArg("b")}, []string{"a"}, "b\nb\n"},
		{"grep", []Arg{StrArg("")}, []string{"a"}, "b\nA\nb\n\nc\n"},
		{"replace", []Arg{StrArg("b"), StrArg("bb")}, []string{"a"}, "bb\nA\nbb\n\nc"},
		{"sort_lines", nil, []string{"a"}, "\nA\nb\nb\nc\n"},
		{"reverse_lines", nil, []string{"a"}, "c\n\nb\nA\nb\n"},
		{"dedup", nil, []string{"a"}, "b\nA\n\nc\n"},
		{"number", nil, []string{"x"}, "1: x\n"},
		{"indent", []Arg{IntArg(2)}, []string{"x"}, "  x\n"},
		{"wrap", []Arg{StrArg("<"), StrArg(">")}, []string{"x"}, "<x\n>"},
		{"count_lines", nil, []string{"a", "x"}, "5 a\n1 x\n6 total\n"},
		{"hash", nil, []string{"x", "x"}, vfs.Hash("x\n") + " x\n" + vfs.Hash("x\n") + " x\n"},
	}
	for _, tc := range tests {
		got := run(t, tc.name, tc.args, tc.inputs, fs).Out
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestRender(t *testing.T) {
	got := Render("replace", []Arg{StrArg("a\\b\"\n\t\r\x01\x7fü"), IntArg(-3)})
	want := `replace("a\\b\"\n\t\r\x01\x7fü", -3)`
	if got != want {
		t.Errorf("got %s, want %s", got, want)
	}
	if got := Render("concat", nil); got != "concat()" {
		t.Errorf("got %s", got)
	}
}

func TestShapeAndArgChecks(t *testing.T) {
	concat, _ := Lookup("concat")
	pre, _ := Lookup("preprocess")
	write, _ := Lookup("write")
	tests := []struct {
		spec *Spec
		in   int
		out  int
		dep  bool
		want string
	}{
		{write, 1, 1, false, "E_CMD_SHAPE write: expected inputs 0-0, got 1"},
		{concat, 0, 1, false, "E_CMD_SHAPE concat: expected inputs 1-N, got 0"},
		{concat, 1, 2, false, "E_CMD_SHAPE concat: expected outputs 1, got 2"},
		{pre, 1, 1, false, "E_CMD_SHAPE preprocess: depfile required"},
		{concat, 1, 1, true, "E_CMD_SHAPE concat: depfile not allowed"},
	}
	for _, tc := range tests {
		err := tc.spec.CheckShape(tc.in, tc.out, tc.dep)
		if err == nil || err.Error() != tc.want {
			t.Errorf("got %v, want %s", err, tc.want)
		}
	}
	if err := concat.CheckShape(3, 1, false); err != nil {
		t.Error(err)
	}
	rep, _ := Lookup("replace")
	if err := rep.CheckArgs([]Arg{StrArg(""), StrArg("x")}); err == nil || err.Error() != "E_ARG cmd replace: empty pattern" {
		t.Errorf("got %v", err)
	}
	ind, _ := Lookup("indent")
	if err := ind.CheckArgs([]Arg{IntArg(-1)}); err == nil || err.Error() != "E_ARG cmd indent: negative" {
		t.Errorf("got %v", err)
	}
}

func TestPreprocess(t *testing.T) {
	fs := workspace(map[string]string{
		"src/main.txt": "title\n@need src/part.txt\nend\n@need \n",
		"src/part.txt": "PART-A\n@need src/deep.txt\n@need src/deep.txt\n",
		"src/deep.txt": "DEEP\n",
	})
	r := run(t, "preprocess", nil, []string{"src/main.txt"}, fs)
	if want := "title\nPART-A\nDEEP\nDEEP\nend\n@need \n"; r.Out != want {
		t.Errorf("Out = %q, want %q", r.Out, want)
	}
	if want := "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n"; r.Depfile != want {
		t.Errorf("Depfile = %q", r.Depfile)
	}
	if want := []string{"src/deep.txt", "src/part.txt"}; !reflect.DeepEqual(r.Discovered, want) {
		t.Errorf("Discovered = %v", r.Discovered)
	}
}

func TestPreprocessErrors(t *testing.T) {
	pre, _ := Lookup("preprocess")
	tests := []struct {
		files map[string]string
		want  string
	}{
		{map[string]string{"m": "@need bad path\n"}, "E_NEED_PATH bad path"},
		{map[string]string{"m": "@need gone\n"}, "E_NEED_MISSING gone needed by m"},
		{map[string]string{"m": "@need a\n", "a": "@need m\n"}, "E_NEED_CYCLE m"},
		{map[string]string{"m": "@need m\n"}, "E_NEED_CYCLE m"},
	}
	for _, tc := range tests {
		_, err := Run(pre, nil, []string{"m"}, workspace(tc.files))
		if ke, ok := err.(*kerr.Error); !ok || ke.Error() != tc.want {
			t.Errorf("got %v, want %s", err, tc.want)
		}
	}
	if _, err := Run(pre, nil, []string{"m"}, workspace(map[string]string{
		"m": strings.Repeat("x\n", 3), "x": "",
	})); err != nil {
		t.Error(err)
	}
}

func TestLines(t *testing.T) {
	tests := map[string][]string{
		"": nil, "\n": {""}, "a\nb\n": {"a", "b"}, "a\nb": {"a", "b"}, "a\n\nb\n": {"a", "", "b"}, "a\r\n": {"a\r"},
	}
	for in, want := range tests {
		if got := Lines(in); !reflect.DeepEqual(got, want) {
			t.Errorf("Lines(%q) = %q, want %q", in, got, want)
		}
	}
}
