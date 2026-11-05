package cmds

import (
	"strings"
	"testing"

	"buildsys/diag"
	"buildsys/vfs"
)

func cmd(name string, args ...any) *Command {
	c := &Command{Spec: Lookup(name)}
	for _, a := range args {
		switch v := a.(type) {
		case string:
			c.Args = append(c.Args, Arg{Str: v})
		case int:
			c.Args = append(c.Args, Arg{IsInt: true, Int: int64(v)})
		}
	}
	return c
}

func in(path, content string) Input {
	b := []byte(content)
	return Input{Path: path, Content: b, Hash: vfs.Hash64(b)}
}

func run(t *testing.T, c *Command, ins ...Input) string {
	t.Helper()
	r, err := Execute(c, ins, vfs.New())
	if err != nil {
		t.Fatal(err)
	}
	return string(r.Out)
}

func TestCanonicalString(t *testing.T) {
	cases := []struct {
		c    *Command
		want string
	}{
		{cmd("write", "hello\n"), `write("hello\n")`},
		{cmd("replace", `a\b`, "c"), `replace("a\\b", "c")`},
		{cmd("indent", 4), `indent(4)`},
		{cmd("wrap", "<<", ">>"), `wrap("<<", ">>")`},
		{cmd("grep", "ü"), `grep("ü")`},
		{cmd("preprocess"), `preprocess()`},
		{cmd("write", "\"\t\r\x00\x7f\x1f"), `write("\"\t\r\x00\x7f\x1f")`},
		{cmd("indent", -3), `indent(-3)`},
	}
	for _, c := range cases {
		got := c.c.String()
		if got != c.want {
			t.Errorf("got %s want %s", got, c.want)
		}
	}
}

func TestShape(t *testing.T) {
	if err := Lookup("write").CheckShape(1, 1, false); err == nil || err.Error() != "E_CMD_SHAPE write: expected inputs 0-0, got 1" {
		t.Errorf("got %v", err)
	}
	if err := Lookup("concat").CheckShape(0, 1, false); err == nil || err.Error() != "E_CMD_SHAPE concat: expected inputs 1-N, got 0" {
		t.Errorf("got %v", err)
	}
	if err := Lookup("copy").CheckShape(1, 2, false); err == nil || err.Error() != "E_CMD_SHAPE copy: expected outputs 1, got 2" {
		t.Errorf("got %v", err)
	}
	if err := Lookup("preprocess").CheckShape(1, 1, false); err == nil || err.Error() != "E_CMD_SHAPE preprocess: depfile required" {
		t.Errorf("got %v", err)
	}
	if err := Lookup("copy").CheckShape(1, 1, true); err == nil || err.Error() != "E_CMD_SHAPE copy: depfile not allowed" {
		t.Errorf("got %v", err)
	}
	if err := Lookup("preprocess").CheckShape(1, 1, true); err != nil {
		t.Error(err)
	}
}

func TestCheckArgs(t *testing.T) {
	if err := cmd("replace", "", "x").CheckArgs(); err == nil || err.Error() != "E_ARG cmd replace: empty pattern" {
		t.Errorf("got %v", err)
	}
	if err := cmd("indent", -1).CheckArgs(); err == nil || err.Error() != "E_ARG cmd indent: negative" {
		t.Errorf("got %v", err)
	}
	if err := cmd("indent", 0).CheckArgs(); err != nil {
		t.Error(err)
	}
}

func TestLines(t *testing.T) {
	cases := map[string]int{"": 0, "a\nb\n": 2, "a\nb": 2, "a\n\nb\n": 3, "\n": 1}
	for s, n := range cases {
		if got := len(Lines([]byte(s))); got != n {
			t.Errorf("Lines(%q) = %d, want %d", s, got, n)
		}
		if CountLines([]byte(s)) != n {
			t.Errorf("CountLines(%q) != %d", s, n)
		}
	}
}

func TestSimpleCommands(t *testing.T) {
	if got := run(t, cmd("upper"), in("a", "aZé\n")); got != "AZé\n" {
		t.Errorf("upper %q", got)
	}
	if got := run(t, cmd("lower"), in("a", "aZÉ\n")); got != "azÉ\n" {
		t.Errorf("lower %q", got)
	}
	if got := run(t, cmd("grep", "b"), in("a", "ab\nc\nb")); got != "ab\nb\n" {
		t.Errorf("grep %q", got)
	}
	if got := run(t, cmd("grep", ""), in("a", "x\ny")); got != "x\ny\n" {
		t.Errorf("grep empty %q", got)
	}
	if got := run(t, cmd("replace", "aa", "b"), in("a", "aaaa a\naaa")); got != "bb a\nba" {
		t.Errorf("replace %q", got)
	}
	if got := run(t, cmd("sort_lines"), in("a", "b\na\nc")); got != "a\nb\nc\n" {
		t.Errorf("sort %q", got)
	}
	if got := run(t, cmd("reverse_lines"), in("a", "1\n2\n3\n")); got != "3\n2\n1\n" {
		t.Errorf("reverse %q", got)
	}
	if got := run(t, cmd("dedup"), in("a", "x\ny\nx\n\n\ny")); got != "x\ny\n\n" {
		t.Errorf("dedup %q", got)
	}
	if got := run(t, cmd("number"), in("a", "a\nb\nc")); got != "1: a\n2: b\n3: c\n" {
		t.Errorf("number %q", got)
	}
	if got := run(t, cmd("indent", 2), in("a", "a\n\nb")); got != "  a\n  \n  b\n" {
		t.Errorf("indent %q", got)
	}
	if got := run(t, cmd("wrap", "<", ">"), in("a", "x")); got != "<x>" {
		t.Errorf("wrap %q", got)
	}
	if got := run(t, cmd("concat"), in("a", "1"), in("b", "2"), in("a", "1")); got != "121" {
		t.Errorf("concat %q", got)
	}
	if got := run(t, cmd("count_lines"), in("src/a.txt", "x\ny\n"), in("src/b.txt", "")); got != "2 src/a.txt\n0 src/b.txt\n2 total\n" {
		t.Errorf("count_lines %q", got)
	}
	if got := run(t, cmd("hash"), in("h", "hello\n"), in("h", "hello\n")); got != "a9bc80cca21f28b3 h\na9bc80cca21f28b3 h\n" {
		t.Errorf("hash %q", got)
	}
}

func TestPreprocess(t *testing.T) {
	fsys := vfs.New()
	fsys.Write("src/part.txt", []byte("PART\n@need src/deep.txt\n"))
	fsys.Write("src/deep.txt", []byte("DEEP\n"))
	r, err := Execute(cmd("preprocess"), []Input{in("src/main.txt", "title\n@need src/part.txt\n@need src/deep.txt\nend")}, fsys)
	if err != nil {
		t.Fatal(err)
	}
	if string(r.Out) != "title\nPART\nDEEP\nDEEP\nend\n" {
		t.Errorf("out %q", r.Out)
	}
	if string(r.Depfile) != "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n" {
		t.Errorf("depfile %q", r.Depfile)
	}
	if strings.Join(r.Deps, ",") != "src/deep.txt,src/part.txt" {
		t.Errorf("deps %v", r.Deps)
	}
}

func TestPreprocessErrors(t *testing.T) {
	fsys := vfs.New()
	fsys.Write("a", []byte("@need b\n"))
	fsys.Write("b", []byte("@need a\n"))
	fsys.Write("self", []byte("@need self\n"))
	cases := []struct{ main, want string }{
		{"@need bad path\n", "E_NEED_PATH bad path"},
		{"@need nope\n", "E_NEED_MISSING nope needed by main"},
		{"@need a\n", "E_NEED_CYCLE a"},
		{"@need self\n", "E_NEED_CYCLE self"},
	}
	for _, c := range cases {
		_, err := Execute(cmd("preprocess"), []Input{in("main", c.main)}, fsys)
		if err == nil || err.Error() != c.want {
			t.Errorf("%q: got %v want %s", c.main, err, c.want)
		}
		if _, ok := err.(*diag.Error); !ok {
			t.Errorf("not a diag.Error: %T", err)
		}
	}
	// "@need" with nothing after the space is an ordinary line; so is "@needx".
	r, err := Execute(cmd("preprocess"), []Input{in("main", "@need \n@needx y\n")}, fsys)
	if err != nil || string(r.Out) != "@need \n@needx y\n" {
		t.Errorf("got %q %v", r.Out, err)
	}
}
