package gitrepo

import (
	"strings"
	"testing"
)

func run(t *testing.T, r *Repository, line string) (string, bool) {
	out, err := r.Execute(line)
	return string(out), err == nil
}

func TestExecuteCommands(t *testing.T) {
	f := newFixture(t)
	r := f.r
	if out, ok := run(t, r, "count-objects"); !ok || out != "loose: 10\nin-pack: 0\npacks: 0\n" {
		t.Errorf("count-objects: %q", out)
	}
	if out, ok := run(t, r, "rev-parse main^2"); !ok || out != f.s1.String()+"\n" {
		t.Errorf("rev-parse: %q", out)
	}
	out, ok := run(t, r, "log main 3")
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if !ok || len(lines) != 3 || lines[0] != f.c3.String()+" Cy 400 merge" ||
		lines[1] != f.s1.String()+" Bob 300 side" || lines[2] != f.c2.String()+" Ada 200 second" {
		t.Errorf("log: %q", out)
	}
	if out, ok := run(t, r, "log main 0"); !ok || out != "" {
		t.Errorf("log 0: %q %v", out, ok)
	}
	if out, ok := run(t, r, "ls-tree v1"); !ok ||
		out != "100644 blob "+f.blob.String()+"\ta.txt\n040000 tree "+f.tr.mustHash(f, "src")+"\tsrc\n" {
		t.Errorf("ls-tree: %q", out)
	}
	if out, ok := run(t, r, "ls-tree main src"); !ok || !strings.HasSuffix(out, "\tdeep.txt\n") {
		t.Errorf("ls-tree path: %q", out)
	}
	if out, ok := run(t, r, "cat-file "+f.blob.String()[:12]); !ok || out != "blob 9\none file\n" {
		t.Errorf("cat-file: %q", out)
	}
	if out, ok := run(t, r, "diff main~2 main"); !ok || !strings.Contains(out, " A\tsrc/deep.txt\n") ||
		!strings.HasPrefix(out, ":000000 100644 "+strings.Repeat("0", 40)+" ") {
		t.Errorf("diff: %q", out)
	}
	if out, ok := run(t, r, "diff main main"); !ok || out != "" {
		t.Errorf("diff same: %q", out)
	}
}

func TestExecuteFailures(t *testing.T) {
	f := newFixture(t)
	for _, line := range []string{
		"", "nosuch", "log", "log main 1 2", "log main x", "log main -1", "log main ", "log  main",
		"log " + f.tree1.String(), "log " + f.blob.String(),
		"ls-tree", "ls-tree main ", "ls-tree main .", "ls-tree main src/", "ls-tree main /src",
		"ls-tree main src//deep", "ls-tree main a.txt", "ls-tree " + f.blob.String(),
		"cat-file", "cat-file main main", "cat-file nosuch", "diff main", "diff main nosuch",
		"diff " + f.blob.String() + " main", "rev-parse", "rev-parse  HEAD", "rev-parse HEAD ",
		"count-objects x", "LOG main",
	} {
		if out, ok := run(t, f.r, line); ok {
			t.Errorf("%q succeeded: %q", line, out)
		}
	}
}

func (tr *testRepo) mustHash(f *fixture, name string) string {
	t, err := f.r.Tree(f.tree2)
	if err != nil {
		tr.t.Fatal(err)
	}
	e, _ := t.Lookup([]byte(name))
	return e.ID.String()
}

func TestEmptyRepository(t *testing.T) {
	tr := newTestRepo(t)
	r := mustOpen(t, tr)
	if out, ok := run(t, r, "count-objects"); !ok || out != "loose: 0\nin-pack: 0\npacks: 0\n" {
		t.Errorf("count-objects: %q", out)
	}
	if _, ok := run(t, r, "rev-parse HEAD"); ok {
		t.Error("HEAD resolved in an empty repository")
	}
}

func TestOpenErrors(t *testing.T) {
	if _, err := Open("/nonexistent/path/xyz"); err == nil {
		t.Error("Open of missing dir succeeded")
	}
}
