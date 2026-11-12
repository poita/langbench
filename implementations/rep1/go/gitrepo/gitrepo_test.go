package gitrepo

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"gitrepo/internal/testrepo"
	"gitrepo/object"
)

// fixture builds:
//
//	c1 (t=100) --- c2 (t=200) --- c4 merge (t=400, parents c2, c3) <- main (HEAD)
//	      \                        /
//	       ---------- c3 (t=300) -
//
// plus an annotated tag "v1" on c2 and a tag-of-tag "v1-outer".
type fixture struct {
	r              *testrepo.Repo
	repo           *Repo
	b1, b2, b3     object.ID
	t1, t2, t3, t4 object.ID
	c1, c2, c3, c4 object.ID
	tag, tagOuter  object.ID
	sub, nested    object.ID
}

func newFixture(t *testing.T) *fixture {
	r := testrepo.New(t)
	f := &fixture{r: r}
	f.b1 = r.Blob("one\n")
	f.b2 = r.Blob("two\n")
	f.b3 = r.Blob("three\n")
	f.nested = r.Tree(testrepo.Entry{Mode: 0o100644, Name: "deep.txt", ID: f.b3})
	f.sub = r.Tree(
		testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: f.b1},
		testrepo.Entry{Mode: 0o40000, Name: "nested", ID: f.nested},
	)
	f.t1 = r.Tree(testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: f.b1})
	f.t2 = r.Tree(
		testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: f.b2},
		testrepo.Entry{Mode: 0o40000, Name: "sub", ID: f.sub},
	)
	f.t3 = r.Tree(
		testrepo.Entry{Mode: 0o100755, Name: "a.txt", ID: f.b1},
		testrepo.Entry{Mode: 0o120000, Name: "link", ID: f.b2},
	)
	f.t4 = r.Tree(
		testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: f.b2},
		testrepo.Entry{Mode: 0o160000, Name: "mod", ID: object.ID{0xaa}},
		testrepo.Entry{Mode: 0o40000, Name: "sub", ID: f.sub},
	)
	f.c1 = r.Commit(f.t1, nil, 100, "first\n")
	f.c2 = r.Commit(f.t2, []object.ID{f.c1}, 200, "second\n\nbody\n")
	f.c3 = r.Commit(f.t3, []object.ID{f.c1}, 300, "third  \nline two\n\nbody")
	f.c4 = r.Commit(f.t4, []object.ID{f.c2, f.c3}, 400, "merge\n")
	f.tag = r.Tag(f.c2, "commit", "v1")
	f.tagOuter = r.Tag(f.tag, "tag", "v1-outer")
	r.SetRef("refs/heads/main", f.c4)
	r.SetRef("refs/heads/side", f.c3)
	r.SetRef("refs/tags/v1", f.tag)
	r.SetRef("refs/tags/v1-outer", f.tagOuter)
	repo, err := Open(r.Dir)
	if err != nil {
		t.Fatal(err)
	}
	f.repo = repo
	return f
}

func TestRevParse(t *testing.T) {
	f := newFixture(t)
	short := f.c4.String()[:7]
	for _, tc := range []struct {
		rev  string
		want object.ID
	}{
		{"HEAD", f.c4},
		{"main", f.c4},
		{"refs/heads/main", f.c4},
		{"heads/main", f.c4},
		{"side", f.c3},
		{"v1", f.tag},
		{"v1^{}", f.c2},
		{"v1^{commit}", f.c2},
		{"v1^{tree}", f.t2},
		{"v1-outer^{}", f.c2},
		{"v1-outer^{tag}", f.tagOuter},
		{"v1^{object}", f.tag},
		{"main^", f.c2},
		{"main^1", f.c2},
		{"main^2", f.c3},
		{"main^0", f.c4},
		{"main~", f.c2},
		{"main~0", f.c4},
		{"main~2", f.c1},
		{"main^2^", f.c1},
		{"main^^", f.c1},
		{"main^{tree}", f.t4},
		{"main^{tree}^{tree}", f.t4},
		{short, f.c4},
		{strings.ToUpper(short), f.c4},
		{f.c4.String(), f.c4},
		{"v1~1", f.c1},
		{"v1^{}~1", f.c1},
	} {
		got, err := f.repo.RevParse(tc.rev)
		if err != nil || got != tc.want {
			t.Errorf("RevParse(%q) = %v, %v; want %v", tc.rev, got, err, tc.want)
		}
	}
}

func TestRevParseFailures(t *testing.T) {
	f := newFixture(t)
	f.r.Write("config", "x")
	for _, rev := range []string{
		"", "nope", "config", "main^3", "main~1^2", "c1~1", "main~3", "v1^{blob}", "v1^{bogus}",
		"main^{tag}", "main^{blob}", "^{}", "^", "~1", "main^{", "main^}", "abc", "0000", "zzzz",
		"refs/heads/", "refs//heads/main", "refs/heads/../heads/main", "./HEAD", "HEAD/", "main ",
		strings.Repeat("0", 40), f.t1.String() + "0", f.b1.String()[:39] + "g",
		f.c4.String() + "^{blob}",
	} {
		if got, err := f.repo.RevParse(rev); err == nil {
			t.Errorf("RevParse(%q) = %v, want failure", rev, got)
		}
	}
}

func TestRevParseAbbrevAmbiguity(t *testing.T) {
	r := testrepo.New(t)
	for _, last := range []byte{1, 2} {
		id := object.ID{0xab, 0xcd, last}
		r.LooseRaw(id, testrepo.Deflate(testrepo.Stored(object.Blob, nil)))
	}
	repo, _ := Open(r.Dir)
	if _, err := repo.RevParse("abcd"); err == nil {
		t.Error("ambiguous abbreviation resolved")
	}
	if _, err := repo.RevParse("abcd01"); err != nil {
		t.Errorf("unique abbreviation: %v", err)
	}
	// A ref named like an abbreviation wins over the object id rule.
	r.SetRef("refs/heads/abcd", object.ID{9})
	repo, _ = Open(r.Dir)
	if id, err := repo.RevParse("abcd"); err != nil || id != (object.ID{9}) {
		t.Errorf("ref should win: %v, %v", id, err)
	}
}

func TestRefLookupOrderAndSymrefs(t *testing.T) {
	r := testrepo.New(t)
	id := func(n byte) object.ID { return object.ID{n} }
	r.SetRef("refs/heads/x", id(1))
	r.SetRef("refs/tags/x", id(2))
	r.SetRef("refs/remotes/x", id(3))
	r.SetRef("refs/x", id(4))
	r.SetRef("refs/heads/only-head", id(5))
	r.SetRef("refs/remotes/o/main", id(6))
	r.Write("refs/remotes/o/HEAD", "ref: refs/remotes/o/main\n")
	// refs/chain0 -> chain1 -> ... -> chain5 (an id): five hops.
	for i := 0; i < 5; i++ {
		r.Write(fmt.Sprintf("refs/chain%d", i), fmt.Sprintf("ref: refs/chain%d", i+1))
	}
	r.SetRef("refs/chain5", id(7))
	r.Write("refs/chain-1", "ref: refs/chain0") // six hops
	r.Write("refs/broken", "not an id\n")
	r.Write("refs/dangling", "ref: refs/missing\n")
	r.Write("refs/spaces", id(8).String()+" \t\r\n")
	r.Write("refs/upper", strings.ToUpper(object.ID{0xab}.String())+"\n")
	r.Write("packed-refs", "# pack-refs with: peeled\n"+
		id(10).String()+" refs/heads/packed\n"+
		"^"+id(11).String()+"\n"+
		id(12).String()+" refs/heads/x\n"+ // shadowed by the loose file
		id(13).String()+" refs/heads/via-packed\n"+
		id(14).String()+" other/name\n")
	r.Write("refs/pointer", "ref: refs/heads/via-packed\n")
	repo, err := Open(r.Dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		rev  string
		want object.ID
		ok   bool
	}{
		{"refs/heads/x", id(1), true},
		{"x", id(4), true}, // refs/x comes before refs/tags/x and refs/heads/x
		{"tags/x", id(2), true},
		{"remotes/x", id(3), true},
		{"only-head", id(5), true},
		{"o", id(6), true}, // refs/remotes/o/HEAD
		{"refs/chain0", id(7), true},
		{"refs/chain-1", object.ID{}, false},
		{"refs/broken", object.ID{}, false},
		{"refs/dangling", object.ID{}, false},
		{"refs/spaces", id(8), true},
		{"refs/upper", object.ID{}, false},
		{"packed", id(10), true},
		{"refs/pointer", id(13), true},
		{"other/name", object.ID{}, false},
	} {
		got, err := repo.RevParse(tc.rev)
		if (err == nil) != tc.ok || (tc.ok && got != tc.want) {
			t.Errorf("RevParse(%q) = %v, %v; want %v (ok=%v)", tc.rev, got, err, tc.want, tc.ok)
		}
	}
	// Refs are taken at face value: HEAD -> main -> nothing yet.
	if _, err := repo.ReadRef("HEAD"); !errors.Is(err, ErrRefNotFound) {
		t.Errorf("HEAD err = %v", err)
	}
	if id, err := repo.ReadRef("refs/heads/via-packed"); err != nil || id != (object.ID{13}) {
		t.Errorf("packed ref: %v, %v", id, err)
	}
}

func TestLog(t *testing.T) {
	f := newFixture(t)
	entries, err := f.repo.Log("HEAD", -1)
	if err != nil {
		t.Fatal(err)
	}
	var got []object.ID
	for _, e := range entries {
		got = append(got, e.ID)
	}
	want := []object.ID{f.c4, f.c3, f.c2, f.c1}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("order = %v, want %v", got, want)
	}
	if e := entries[1]; string(e.Author) != "Ada" || e.AuthorTime != 300 || string(e.Subject) != "third line two" {
		t.Errorf("entry = %+v", e)
	}
	if es, err := f.repo.Log("main", 2); err != nil || len(es) != 2 {
		t.Errorf("limit 2: %d, %v", len(es), err)
	}
	if es, err := f.repo.Log("main", 0); err != nil || len(es) != 0 {
		t.Errorf("limit 0: %d, %v", len(es), err)
	}
	if es, err := f.repo.Log("v1", -1); err != nil || len(es) != 2 || es[0].ID != f.c2 {
		t.Errorf("log of tag: %v, %v", es, err)
	}
	if _, err := f.repo.Log("main^{tree}", -1); err == nil {
		t.Error("log of a tree succeeded")
	}
	if _, err := f.repo.Log("nope", -1); err == nil {
		t.Error("log of unknown rev succeeded")
	}
}

func TestLogTieBreakByDiscoveryOrder(t *testing.T) {
	r := testrepo.New(t)
	tree := r.Tree()
	root := r.Commit(tree, nil, 10, "root\n")
	p1 := r.Commit(tree, []object.ID{root}, 50, "p1\n")
	p2 := r.Commit(tree, []object.ID{root}, 50, "p2\n")
	p3 := r.Commit(tree, []object.ID{root}, 50, "p3\n")
	top := r.Commit(tree, []object.ID{p2, p3, p1}, 50, "top\n")
	r.SetRef("refs/heads/main", top)
	repo, _ := Open(r.Dir)
	es, err := repo.Log("main", -1)
	if err != nil {
		t.Fatal(err)
	}
	var got []object.ID
	for _, e := range es {
		got = append(got, e.ID)
	}
	want := []object.ID{top, p2, p3, p1, root}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %v\nwant %v", got, want)
	}
}

func TestLogMissingParentFails(t *testing.T) {
	r := testrepo.New(t)
	tree := r.Tree()
	c := r.Commit(tree, []object.ID{{0xde, 0xad}}, 10, "orphan\n")
	r.SetRef("refs/heads/main", c)
	repo, _ := Open(r.Dir)
	if _, err := repo.Log("main", -1); err == nil {
		t.Error("expected failure for a missing parent")
	}
}

func TestLsTree(t *testing.T) {
	f := newFixture(t)
	es, err := f.repo.LsTree("main", "")
	if err != nil || len(es) != 3 || string(es[1].Name) != "mod" || es[1].Type() != object.Commit {
		t.Fatalf("root: %v, %v", es, err)
	}
	es, err = f.repo.LsTree("main", "sub/nested")
	if err != nil || len(es) != 1 || string(es[0].Name) != "deep.txt" {
		t.Fatalf("sub/nested: %v, %v", es, err)
	}
	if es, err := f.repo.LsTree(f.c2.String()+"^{tree}", "sub"); err != nil || len(es) != 2 {
		t.Errorf("tree rev: %v, %v", es, err)
	}
	for _, path := range []string{".", "src/", "/sub", "sub//nested", "sub/../sub", "nope", "a.txt", "sub/a.txt", "mod"} {
		if _, err := f.repo.LsTree("main", path); err == nil {
			t.Errorf("LsTree(main, %q) succeeded", path)
		}
	}
	if _, err := f.repo.LsTree(f.b1.String(), ""); err == nil {
		t.Error("LsTree of a blob succeeded")
	}
}

func TestCatFile(t *testing.T) {
	f := newFixture(t)
	o, err := f.repo.CatFile(f.b1.String())
	if err != nil || o.Type != object.Blob || string(o.Data) != "one\n" {
		t.Fatalf("got %+v, %v", o, err)
	}
	if o, err := f.repo.CatFile("v1"); err != nil || o.Type != object.Tag {
		t.Errorf("tag: %+v, %v", o, err)
	}
	// An object stored under the wrong id fails verification.
	wrong := object.ID{0x5a}
	f.r.LooseRaw(wrong, testrepo.Deflate(testrepo.Stored(object.Blob, []byte("liar"))))
	repo, _ := Open(f.r.Dir)
	if _, err := repo.CatFile(wrong.String()); err == nil {
		t.Error("hash mismatch not detected")
	}
	if _, err := repo.CatFile(object.ID{0x6b}.String()); err == nil {
		t.Error("missing object succeeded")
	}
}

func TestDiff(t *testing.T) {
	f := newFixture(t)
	es, err := f.repo.Diff(f.c2.String(), f.c4.String())
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 1 || string(es[0].Path) != "mod" || es[0].Status != 'A' || es[0].NewMode != 0o160000 {
		t.Errorf("c2..c4 = %+v", es)
	}

	es, err = f.repo.Diff(f.c1.String(), f.c2.String())
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, e := range es {
		paths = append(paths, fmt.Sprintf("%c %s", e.Status, e.Path))
	}
	if fmt.Sprint(paths) != "[M a.txt A sub/a.txt A sub/nested/deep.txt]" {
		t.Errorf("c1..c2 = %v", paths)
	}

	// Mode change only: M. File replaced by symlink or tree: T / D+A.
	es, _ = f.repo.Diff(f.c1.String(), f.c3.String())
	if len(es) != 2 || es[0].Status != 'M' || es[0].OldMode != 0o100644 || es[0].NewMode != 0o100755 || es[1].Status != 'A' {
		t.Errorf("c1..c3 = %+v", es)
	}
	if es, _ := f.repo.Diff(f.c3.String(), f.c4.String()); len(es) == 0 {
		t.Error("c3..c4 empty")
	}
	if es, err := f.repo.Diff("main", "main"); err != nil || len(es) != 0 {
		t.Errorf("self diff: %v, %v", es, err)
	}
	// Reverse swaps sides.
	es, _ = f.repo.Diff(f.c2.String(), f.c1.String())
	if es[1].Status != 'D' || es[1].OldID == (object.ID{}) {
		t.Errorf("reverse = %+v", es)
	}
	if _, err := f.repo.Diff("main", f.b1.String()); err == nil {
		t.Error("diff against a blob succeeded")
	}
}

func TestDiffTypeChangeAndSorting(t *testing.T) {
	r := testrepo.New(t)
	b := r.Blob("x")
	d := r.Tree(testrepo.Entry{Mode: 0o100644, Name: "x", ID: b})
	// a.txt sorts before a/x as raw bytes ('.' < '/'), unlike git's tree order.
	t1 := r.Tree(
		testrepo.Entry{Mode: 0o100644, Name: "a", ID: b},
		testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: b},
		testrepo.Entry{Mode: 0o100644, Name: "z", ID: b},
	)
	t2 := r.Tree(
		testrepo.Entry{Mode: 0o120000, Name: "a", ID: b},
		testrepo.Entry{Mode: 0o100644, Name: "a.txt", ID: b},
		testrepo.Entry{Mode: 0o40000, Name: "z", ID: d},
	)
	repo, _ := Open(r.Dir)
	es, err := repo.Diff(t1.String(), t2.String())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range es {
		got = append(got, fmt.Sprintf("%c:%s", e.Status, e.Path))
	}
	if fmt.Sprint(got) != "[T:a D:z A:z/x]" {
		t.Errorf("got %v", got)
	}
}

func TestQuotePath(t *testing.T) {
	for in, want := range map[string]string{
		"plain.txt":           "plain.txt",
		"with space":          "with space",
		"caf\u00e9.txt":       `"caf\303\251.txt"`,
		`quote"and\slash.txt`: `"quote\"and\\slash.txt"`,
		"tab\there":           `"tab\there"`,
		"\a\b\n\v\f\r":        `"\a\b\n\v\f\r"`,
		"\x01\x1f\x7f":        `"\001\037\177"`,
		"":                    "",
		"~":                   "~",
	} {
		if got := string(QuotePath([]byte(in))); got != want {
			t.Errorf("QuotePath(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestCountObjects(t *testing.T) {
	f := newFixture(t)
	if c := f.repo.CountObjects(); c.Loose != 15 || c.InPack != 0 || c.Packs != 0 {
		t.Errorf("counts = %+v", c)
	}
}
