package gitrepo

import (
	"errors"
	"strings"
	"testing"
)

// history builds:
//
//	c1 <- c2 <- c3 (main, HEAD)       c3 has parents c2 and s1
//	c1 <- s1 (side)
//
// with tag objects v1 (annotated, -> c2) and a packed ref.
type fixture struct {
	tr                 *testRepo
	r                  *Repository
	blob, tree1, tree2 ID
	c1, c2, s1, c3     ID
	tag                ID
}

func newFixture(t *testing.T) *fixture {
	tr := newTestRepo(t)
	f := &fixture{tr: tr}
	f.blob = tr.loose(TypeBlob, []byte("one file\n"))
	blob2 := tr.loose(TypeBlob, []byte("two\n"))
	sub := tr.loose(TypeTree, treePayload(treeEntry{"100644", "deep.txt", blob2}))
	f.tree1 = tr.loose(TypeTree, treePayload(treeEntry{"100644", "a.txt", f.blob}))
	f.tree2 = tr.loose(TypeTree, treePayload(
		treeEntry{"100644", "a.txt", f.blob},
		treeEntry{"40000", "src", sub},
	))
	f.c1 = tr.commit(f.tree1, nil, "Ada", 100, 1000, "first\n")
	f.c2 = tr.commit(f.tree2, []ID{f.c1}, "Ada", 200, 2000, "second\n\nbody\n")
	f.s1 = tr.commit(f.tree1, []ID{f.c1}, "Bob", 300, 2500, "side\n")
	f.c3 = tr.commit(f.tree2, []ID{f.c2, f.s1}, "Cy", 400, 3000, "merge\n")
	tagPayload := "object " + f.c2.String() + "\ntype commit\ntag v1\ntagger T <t@x> 1 +0000\n\nrelease\n"
	f.tag = tr.loose(TypeTag, []byte(tagPayload))
	tr.ref("refs/heads/main", f.c3.String())
	tr.ref("refs/heads/side", f.s1.String())
	tr.ref("refs/tags/v1", f.tag.String())
	tr.ref("HEAD", "ref: refs/heads/main")
	tr.write("packed-refs", []byte("# pack-refs with: peeled\n"+f.c1.String()+" refs/heads/old\n^"+f.c2.String()+"\n"+
		f.s1.String()+" refs/heads/main\n")) // loose main must win
	f.r = mustOpen(t, tr)
	return f
}

func TestResolveRevision(t *testing.T) {
	f := newFixture(t)
	cases := map[string]ID{
		"HEAD":                         f.c3,
		"main":                         f.c3,
		"heads/main":                   f.c3,
		"refs/heads/main":              f.c3,
		"old":                          f.c1, // from packed-refs
		"v1":                           f.tag,
		"v1^{}":                        f.c2,
		"v1^{commit}":                  f.c2,
		"v1^{tree}":                    f.tree2,
		"v1^{tag}":                     f.tag,
		"v1^{object}":                  f.tag,
		"main^":                        f.c2,
		"main^1":                       f.c2,
		"main^2":                       f.s1,
		"main^0":                       f.c3,
		"main~":                        f.c2,
		"main~2":                       f.c1,
		"main~2^0":                     f.c1,
		"main^2~":                      f.c1,
		"main^^":                       f.c1,
		"main^{tree}":                  f.tree2,
		"main^{commit}~1":              f.c2,
		"v1~":                          f.c1,
		strings.ToUpper(f.c2.String()): f.c2,
		f.c2.String()[:10]:             f.c2,
		f.c2.String() + "^":            f.c1,
		f.tree1.String():               f.tree1,
	}
	for rev, want := range cases {
		got, err := f.r.ResolveRevision(rev)
		if err != nil || got != want {
			t.Errorf("%s = %v, %v; want %s", rev, got, err, want)
		}
	}
}

func TestResolveRevisionFailures(t *testing.T) {
	f := newFixture(t)
	missing := strings.Repeat("ab", 20)
	for _, rev := range []string{
		"", "nosuch", "config", "main^3", "main~9", "c1^{}x", "main^{bogus}", "main^{blob}",
		"^{}", "~1", "^", "v1^{tree}^{blob}", f.c1.String()[:3], missing, "main^{", "refs//heads/main",
		"refs/heads/../heads/main", "HEAD^{tag}", f.tree1.String() + "^", f.blob.String() + "^{tree}",
	} {
		if got, err := f.r.ResolveRevision(rev); err == nil {
			t.Errorf("%q resolved to %s", rev, got)
		}
	}
}

func TestRefDetails(t *testing.T) {
	tr := newTestRepo(t)
	id := strings.Repeat("1", 40)
	tr.ref("refs/heads/a", "ref: refs/heads/b")
	tr.ref("refs/heads/b", "ref: refs/heads/c")
	tr.ref("refs/heads/c", id+"  ")
	tr.ref("refs/heads/loop", "ref: refs/heads/loop")
	for i := 0; i < 7; i++ {
		tr.ref("refs/heads/d"+string(rune('0'+i)), "ref: refs/heads/d"+string(rune('1'+i)))
	}
	tr.ref("refs/heads/d7", id)
	tr.ref("refs/heads/bad", "zzz")
	tr.write("config", []byte(id+"\n"))
	r := mustOpen(t, tr)
	for name, ok := range map[string]bool{
		"refs/heads/a": true, "refs/heads/c": true, "refs/heads/loop": false,
		"refs/heads/d2":  true,  // 5 symref hops
		"refs/heads/d1":  false, // 6 hops
		"refs/heads/bad": false, "config": false, "HEAD": false, "refs/heads": false,
	} {
		got, found := r.ResolveRef(name)
		if found != ok || (ok && got.String() != id) {
			t.Errorf("ResolveRef(%s) = %v %v, want ok=%v", name, got, found, ok)
		}
	}
	// A ref may point at an object that does not exist.
	if got, err := r.ResolveRevision("a"); err != nil || got.String() != id {
		t.Errorf("dangling ref: %v %v", got, err)
	}
}

func TestPeel(t *testing.T) {
	f := newFixture(t)
	if got, err := f.r.Peel(f.tag, TypeTree); err != nil || got != f.tree2 {
		t.Errorf("tag->tree: %v %v", got, err)
	}
	if _, err := f.r.Peel(f.tree1, TypeCommit); !errors.Is(err, ErrType) {
		t.Errorf("tree->commit: %v", err)
	}
	if _, err := f.r.Peel(f.blob, TypeTree); !errors.Is(err, ErrType) {
		t.Errorf("blob->tree: %v", err)
	}
	if _, err := f.r.Peel(ID{3}, TypeTree); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
}
