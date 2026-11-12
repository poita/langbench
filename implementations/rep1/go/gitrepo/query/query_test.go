package query

import (
	"strings"
	"testing"

	"gitrepo"
	"gitrepo/internal/testrepo"
	"gitrepo/object"
)

func fixture(t *testing.T) (*gitrepo.Repo, object.ID, object.ID) {
	r := testrepo.New(t)
	b := r.Blob("one file\n")
	tree := r.Tree(testrepo.Entry{Mode: 0o100644, Name: "caf\u00e9.txt", ID: b})
	c1 := r.Commit(object.Hash(object.Tree, nil), nil, 1400000000, "Empty tree commit\n")
	r.Loose(object.Tree, nil)
	c2 := r.Commit(tree, []object.ID{c1}, 1400003600, "Add only.txt\n")
	r.SetRef("refs/heads/main", c2)
	repo, err := gitrepo.Open(r.Dir)
	if err != nil {
		t.Fatal(err)
	}
	return repo, b, c2
}

func TestExecute(t *testing.T) {
	repo, b, c2 := fixture(t)
	for _, tc := range []struct{ line, want string }{
		{"count-objects", "loose: 5\nin-pack: 0\npacks: 0\n"},
		{"rev-parse main", c2.String() + "\n"},
		{"rev-parse main~1^{tree}", "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"},
		{"cat-file " + b.String(), "blob 9\none file\n"},
		{"ls-tree main", "100644 blob " + b.String() + "\t\"caf\\303\\251.txt\"\n"},
		{"ls-tree main~1", ""},
		{"log main 1", c2.String() + " Ada 1400003600 Add only.txt\n"},
		{"log main 0", ""},
		{"log HEAD 00", ""},
		{"log main 99999999999999999999", c2.String() + " Ada 1400003600 Add only.txt\n" +
			func() string { id, _ := repo.RevParse("main~1"); return id.String() }() + " Ada 1400000000 Empty tree commit\n"},
		{"diff main~1 main", ":000000 100644 " + strings.Repeat("0", 40) + " " + b.String() + " A\t\"caf\\303\\251.txt\"\n"},
	} {
		got, err := Execute(repo, tc.line)
		if err != nil || string(got) != tc.want {
			t.Errorf("%q = %q, %v; want %q", tc.line, got, err, tc.want)
		}
	}
}

func TestExecuteFailures(t *testing.T) {
	repo, _, _ := fixture(t)
	for _, line := range []string{
		"", " ", "frobnicate", "rev-parse", "rev-parse  main", "rev-parse main ", "rev-parse a b",
		"count-objects ", "count-objects x", "log", "log main 1x", "log main -1", "log main ", "log main 1 2",
		"log nope", "log main^{tree}", "ls-tree", "ls-tree main ", "ls-tree main src/", "ls-tree main a b",
		"ls-tree main^{blob}", "cat-file", "cat-file nope", "cat-file a b", "diff", "diff main", "diff main main main",
		"diff main  main", "LOG main", "rev-parse HEAD", // HEAD points at main, which exists, so this one succeeds below
	} {
		out, err := Execute(repo, line)
		if line == "rev-parse HEAD" {
			if err != nil {
				t.Errorf("%q failed: %v", line, err)
			}
			continue
		}
		if err == nil || out != nil {
			t.Errorf("%q = %q, %v; want failure", line, out, err)
		}
	}
}
