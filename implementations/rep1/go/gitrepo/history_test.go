package gitrepo

import (
	"strings"
	"testing"
)

func TestWalkOrder(t *testing.T) {
	f := newFixture(t)
	var got []ID
	err := f.r.Walk(f.c3, -1, func(id ID, c *Commit) { got = append(got, id) })
	if err != nil {
		t.Fatal(err)
	}
	// dates: c3=3000, s1=2500, c2=2000, c1=1000
	want := []ID{f.c3, f.s1, f.c2, f.c1}
	if len(got) != len(want) {
		t.Fatalf("got %d commits", len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("position %d: %s, want %s", i, got[i], want[i])
		}
	}
	got = got[:0]
	f.r.Walk(f.c3, 2, func(id ID, c *Commit) { got = append(got, id) })
	if len(got) != 2 {
		t.Errorf("limit 2 gave %d", len(got))
	}
	got = got[:0]
	if err := f.r.Walk(f.c3, 0, func(id ID, c *Commit) { got = append(got, id) }); err != nil || len(got) != 0 {
		t.Errorf("limit 0: %v %d", err, len(got))
	}
}

func TestWalkTieBreak(t *testing.T) {
	tr := newTestRepo(t)
	tree := tr.loose(TypeTree, nil)
	root := tr.commit(tree, nil, "A", 1, 10, "root\n")
	l := tr.commit(tree, []ID{root}, "A", 2, 50, "left\n")
	m := tr.commit(tree, []ID{root}, "A", 3, 50, "mid\n")
	rt := tr.commit(tree, []ID{root}, "A", 4, 50, "right\n")
	top := tr.commit(tree, []ID{l, m, rt}, "A", 5, 60, "top\n")
	r := mustOpen(t, tr)
	var got []ID
	r.Walk(top, -1, func(id ID, c *Commit) { got = append(got, id) })
	want := []ID{top, l, m, rt, root} // equal dates: discovery (header) order
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("position %d wrong: %v", i, got)
		}
	}
}

func TestWalkMissingParent(t *testing.T) {
	tr := newTestRepo(t)
	tree := tr.loose(TypeTree, nil)
	c := tr.commit(tree, []ID{{5}}, "A", 1, 1, "orphan\n")
	r := mustOpen(t, tr)
	if err := r.Walk(c, -1, func(ID, *Commit) {}); err == nil {
		t.Error("walk through a missing parent succeeded")
	}
	// Even at the limit, the parent of the last commit is loaded.
	if err := r.Walk(c, 1, func(ID, *Commit) {}); err == nil {
		t.Error("walk with limit did not load the parent")
	}
}

func TestCommitParsing(t *testing.T) {
	msg := "\n\nFix the thing   \nand the other\n\nbody\n"
	raw := "tree " + strings.Repeat("a", 40) + "\n" +
		"parent " + strings.Repeat("b", 40) + "\n" +
		"parent " + strings.Repeat("c", 40) + "\n" +
		"author Jane Q. Public  <j@x.org> 1234567 +0100\n" +
		"committer Other <o@x.org> +987 -0500\n" +
		"gpgsig -----BEGIN\n \n tree 1111\n -----END\n" +
		"committer Last <l@x.org> 55 +0000\n\n" + msg
	c, err := parseCommit([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Parents) != 2 || c.CommitterTime != 55 || c.AuthorTime != 1234567 {
		t.Errorf("parsed %+v", c)
	}
	if c.Tree.String() != strings.Repeat("aa", 20) {
		t.Errorf("tree %s (continuation line leaked?)", c.Tree)
	}
	if string(c.AuthorName) != "Jane Q. Public" || string(c.Subject) != "Fix the thing and the other" {
		t.Errorf("name %q subject %q", c.AuthorName, c.Subject)
	}
	if string(c.LogSuffix) != "Jane Q. Public 1234567 Fix the thing and the other" {
		t.Errorf("suffix %q", c.LogSuffix)
	}
}

func TestIdentEdgeCases(t *testing.T) {
	cases := []struct {
		in   string
		name string
		ts   uint64
	}{
		{"No Email 5 +0000", "No Email 5 +0000", 0},
		{"N <e> 12 +0000", "N", 12},
		{"N <e>    -77 +0000", "N", 77},
		{"N <e> abc", "N", 0},
		{"N <e", "N", 0},
		{"<e> 9", "", 9},
	}
	for _, c := range cases {
		name, ts := parseIdent([]byte(c.in))
		if string(name) != c.name || ts != c.ts {
			t.Errorf("%q -> %q %d", c.in, name, ts)
		}
	}
	if s := subject([]byte("\n \t\n")); len(s) != 0 {
		t.Errorf("blank message subject %q", s)
	}
	c, err := parseCommit([]byte("tree " + strings.Repeat("a", 40) + "\nauthor A <a> 1 +0\n"))
	if err != nil || string(c.LogSuffix) != "A 1 " {
		t.Errorf("no message: %q %v", c.LogSuffix, err)
	}
}
