package cmds

import (
	"testing"

	"kiln/errs"
	"kiln/vfs"
)

func run(t *testing.T, name string, args []Arg, inputs ...string) string {
	t.Helper()
	spec, ok := Lookup(name)
	if !ok {
		t.Fatalf("no command %s", name)
	}
	in := make([]Input, len(inputs))
	for i, s := range inputs {
		in[i] = Input{Path: "in" + string(rune('0'+i)), Data: []byte(s), Hash: vfs.Hash([]byte(s))}
	}
	res, err := spec.Run(args, in, vfs.New())
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return string(res.Output)
}

func TestCommands(t *testing.T) {
	s, i := StrArg, IntArg
	cases := []struct {
		name string
		args []Arg
		in   []string
		want string
	}{
		{"write", []Arg{s("hi\n")}, nil, "hi\n"},
		{"copy", nil, []string{"x"}, "x"},
		{"concat", nil, []string{"a", "b"}, "ab"},
		{"upper", nil, []string{"aé z"}, "Aé Z"},
		{"lower", nil, []string{"AÉ Z"}, "aÉ z"},
		{"grep", []Arg{s("b")}, []string{"ab\ncd\nb"}, "ab\nb\n"},
		{"grep", []Arg{s("")}, []string{"a\n\nb"}, "a\n\nb\n"},
		{"replace", []Arg{s("aa"), s("b")}, []string{"aaaaa"}, "bba"},
		{"sort_lines", nil, []string{"b\na\nc"}, "a\nb\nc\n"},
		{"reverse_lines", nil, []string{"a\nb\n"}, "b\na\n"},
		{"dedup", nil, []string{"a\nb\na\nb\nc\n"}, "a\nb\nc\n"},
		{"number", nil, []string{"a\n\nc"}, "1: a\n2: \n3: c\n"},
		{"indent", []Arg{i(2)}, []string{"a\n\n"}, "  a\n  \n"},
		{"wrap", []Arg{s("<"), s(">")}, []string{"x"}, "<x>"},
		{"count_lines", nil, []string{"a\nb\n", ""}, "2 in0\n0 in1\n2 total\n"},
		{"hash", nil, []string{"hello\n"}, "a9bc80cca21f28b3 in0\n"},
		{"sort_lines", nil, []string{""}, ""},
	}
	for _, c := range cases {
		if got := run(t, c.name, c.args, c.in...); got != c.want {
			t.Errorf("%s%v(%q) = %q, want %q", c.name, c.args, c.in, got, c.want)
		}
	}
}

func TestRender(t *testing.T) {
	got := Render("replace", []Arg{StrArg("a\\b\"\n\t\r\x01\x7fü"), IntArg(-4)})
	want := `replace("a\\b\"\n\t\r\x01\x7fü", -4)`
	if got != want {
		t.Errorf("Render = %s, want %s", got, want)
	}
	if got := Render("concat", nil); got != "concat()" {
		t.Errorf("Render = %s", got)
	}
}

func TestSpecs(t *testing.T) {
	if len(Names()) != 16 {
		t.Errorf("want 16 commands, got %d", len(Names()))
	}
	c, _ := Lookup("concat")
	if c.InputRange() != "1-N" || c.DefaultCost != 2 {
		t.Errorf("concat spec wrong: %s %d", c.InputRange(), c.DefaultCost)
	}
	w, _ := Lookup("write")
	if w.InputRange() != "0-0" {
		t.Error("write takes no inputs")
	}
	r, _ := Lookup("replace")
	if r.CheckArgs([]Arg{StrArg(""), StrArg("x")}) == nil {
		t.Error("empty replace pattern accepted")
	}
	ind, _ := Lookup("indent")
	if ind.CheckArgs([]Arg{IntArg(-1)}) == nil {
		t.Error("negative indent accepted")
	}
}

func fsWith(files map[string]string) *vfs.FS {
	fs := vfs.New()
	for p, c := range files {
		fs.Write(p, []byte(c))
	}
	return fs
}

func preprocessRun(fs *vfs.FS, path string) (Result, *errs.Error) {
	spec, _ := Lookup("preprocess")
	data, h, _ := fs.Lookup(path)
	return spec.Run(nil, []Input{{Path: path, Data: data, Hash: h}}, fs)
}

func TestPreprocess(t *testing.T) {
	fs := fsWith(map[string]string{
		"src/main.txt": "title\n@need src/part.txt\n@need src/part.txt\nend",
		"src/part.txt": "PART\n@need src/deep.txt\n@need \n",
		"src/deep.txt": "DEEP\n",
	})
	res, err := preprocessRun(fs, "src/main.txt")
	if err != nil {
		t.Fatal(err)
	}
	if want := "title\nPART\nDEEP\n@need \nPART\nDEEP\n@need \nend\n"; string(res.Output) != want {
		t.Errorf("output = %q, want %q", res.Output, want)
	}
	if want := "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n"; string(res.Depfile) != want {
		t.Errorf("depfile = %q", res.Depfile)
	}
	if len(res.Deps) != 2 || res.Deps[0].Hash != vfs.Hash([]byte("DEEP\n")) {
		t.Errorf("deps = %+v", res.Deps)
	}
}

func TestPreprocessErrors(t *testing.T) {
	cases := []struct {
		files map[string]string
		want  string
	}{
		{map[string]string{"a": "@need Bad Path\n"}, "E_NEED_PATH Bad Path"},
		{map[string]string{"a": "@need gone\n"}, "E_NEED_MISSING gone needed by a"},
		{map[string]string{"a": "@need b\n", "b": "@need a\n"}, "E_NEED_CYCLE a"},
		{map[string]string{"a": "@need b\n", "b": "@need b\n"}, "E_NEED_CYCLE b"},
	}
	for _, c := range cases {
		_, err := preprocessRun(fsWith(c.files), "a")
		if err == nil || err.Error() != c.want {
			t.Errorf("got %v, want %s", err, c.want)
		}
	}
}
