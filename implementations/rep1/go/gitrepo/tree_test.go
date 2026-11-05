package gitrepo

import (
	"errors"
	"testing"
)

func TestTreeParsing(t *testing.T) {
	id := HashObject(TypeBlob, []byte("x"))
	tr, err := parseTree(treePayload(
		treeEntry{"40000", "dir", id}, treeEntry{"160000", "sub", id},
		treeEntry{"120000", "link", id}, treeEntry{"100755", "run", id}))
	if err != nil {
		t.Fatal(err)
	}
	wantTypes := []ObjectType{TypeTree, TypeCommit, TypeBlob, TypeBlob}
	for i, e := range tr.Entries {
		if e.Type() != wantTypes[i] {
			t.Errorf("entry %s type %v", e.Name, e.Type())
		}
	}
	if e, ok := tr.Lookup([]byte("run")); !ok || e.Mode != 0o100755 {
		t.Errorf("Lookup: %v %v", e, ok)
	}
	good := treePayload(treeEntry{"100644", "f", id})
	for _, bad := range [][]byte{good[:len(good)-1], []byte("100644 noterminator"), []byte("1x0644 f\x00" + string(id[:])), []byte(" f\x00" + string(id[:]))} {
		if _, err := parseTree(bad); !errors.Is(err, ErrDamaged) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestLookupPath(t *testing.T) {
	f := newFixture(t)
	if _, err := f.r.LookupPath(f.tree2, "src"); err != nil {
		t.Errorf("src: %v", err)
	}
	for _, p := range []string{"", ".", "..", "src/", "/src", "src//x", "a.txt", "nosuch", "src/deep.txt", "src/.."} {
		if _, err := f.r.LookupPath(f.tree2, p); err == nil {
			t.Errorf("path %q accepted", p)
		}
	}
}

func TestDiffTrees(t *testing.T) {
	tr := newTestRepo(t)
	b1 := tr.loose(TypeBlob, []byte("1"))
	b2 := tr.loose(TypeBlob, []byte("2"))
	sub1 := tr.loose(TypeTree, treePayload(treeEntry{"100644", "x", b1}, treeEntry{"100644", "y", b1}))
	sub2 := tr.loose(TypeTree, treePayload(treeEntry{"100644", "x", b2}, treeEntry{"100644", "z", b1}))
	left := tr.loose(TypeTree, treePayload(
		treeEntry{"100644", "same", b1},
		treeEntry{"100644", "mode", b1},
		treeEntry{"100644", "kind", b1},
		treeEntry{"100644", "gone", b1},
		treeEntry{"40000", "sub", sub1}))
	right := tr.loose(TypeTree, treePayload(
		treeEntry{"100644", "same", b1},
		treeEntry{"100755", "mode", b1},
		treeEntry{"120000", "kind", b1},
		treeEntry{"100644", "new", b2},
		treeEntry{"40000", "sub", sub2}))
	r := mustOpen(t, tr)
	d, err := r.DiffTrees(left, right)
	if err != nil {
		t.Fatal(err)
	}
	type row struct {
		path   string
		status DiffStatus
	}
	want := []row{{"gone", Deleted}, {"kind", TypeChanged}, {"mode", Modified}, {"new", Added},
		{"sub/x", Modified}, {"sub/y", Deleted}, {"sub/z", Added}}
	if len(d) != len(want) {
		t.Fatalf("got %d entries: %+v", len(d), d)
	}
	for i, w := range want {
		if string(d[i].Path) != w.path || d[i].Status != w.status {
			t.Errorf("entry %d = %s %c, want %s %c", i, d[i].Path, d[i].Status, w.path, w.status)
		}
	}
	if d[3].OldMode != 0 || !d[3].OldID.IsZero() || d[3].NewMode != 0o100644 {
		t.Errorf("added entry sides wrong: %+v", d[3])
	}
	if same, _ := r.DiffTrees(left, left); len(same) != 0 {
		t.Error("identical trees differ")
	}
	if _, err := r.DiffTrees(left, ID{8}); err == nil {
		t.Error("missing tree accepted")
	}
}

func TestAppendQuoted(t *testing.T) {
	cases := map[string]string{
		"plain.txt":           "plain.txt",
		"with space":          "with space",
		"café.txt":            `"caf\303\251.txt"`,
		`quote"and\slash.txt`: `"quote\"and\\slash.txt"`,
		"tab\there":           `"tab\there"`,
		"nl\n":                `"nl\n"`,
		"\a\b\v\f\r":          `"\a\b\v\f\r"`,
		"\x01\x7f":            `"\001\177"`,
		"":                    "",
	}
	for in, want := range cases {
		if got := string(AppendQuoted(nil, []byte(in))); got != want {
			t.Errorf("quote(%q) = %s, want %s", in, got, want)
		}
	}
}
