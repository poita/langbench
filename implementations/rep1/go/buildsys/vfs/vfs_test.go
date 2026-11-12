package vfs

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestHash(t *testing.T) {
	tests := map[string]string{
		"":        "cbf29ce484222325",
		"hello\n": "a9bc80cca21f28b3",
		"abc\n":   "fc17b183ee074373",
	}
	for in, want := range tests {
		if got := Hash(in); got != want {
			t.Errorf("Hash(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestValidPath(t *testing.T) {
	long := strings.Repeat("a", 256)
	tests := []struct {
		p  string
		ok bool
	}{
		{"a", true}, {"src/a.txt", true}, {"a+b-c_d.e", true},
		{"", false}, {"/a", false}, {"a/", false}, {"a//b", false},
		{"./a", false}, {"a/..", false}, {"a b", false}, {"a*", false},
		{"@all", false}, {"ü", false}, {long, false}, {strings.Repeat("a", 255), true},
	}
	for _, tc := range tests {
		if got := ValidPath(tc.p); got != tc.ok {
			t.Errorf("ValidPath(%q) = %v, want %v", tc.p, got, tc.ok)
		}
	}
}

func TestGlobIndex(t *testing.T) {
	f := New()
	for _, p := range []string{"src/b", "src/a", "out/x", StateFile, "srcx", "lib", "src/sub/c"} {
		f.Write(p, "x")
	}
	if got, want := f.GlobCandidates("src/"), []string{"src/a", "src/b", "src/sub/c"}; !reflect.DeepEqual(got, want) {
		t.Errorf("GlobCandidates = %v, want %v", got, want)
	}
	f.Delete("src/a")
	if got := f.GlobCandidates("src"); !reflect.DeepEqual(got, []string{"src/b", "src/sub/c", "srcx"}) {
		t.Errorf("after delete: %v", got)
	}
	if got := f.GlobCandidates(""); len(got) != 4 {
		t.Errorf("eligible paths = %v", got)
	}
}

func TestHashCacheInvalidation(t *testing.T) {
	f := New()
	f.Write("a", "one")
	h1, _ := f.Hash("a")
	f.Write("a", "two")
	h2, _ := f.Hash("a")
	if h1 == h2 || h2 != Hash("two") {
		t.Errorf("stale hash: %s %s", h1, h2)
	}
	if _, ok := f.Hash("missing"); ok {
		t.Error("hash of missing file")
	}
}

func TestTouchKeepsContent(t *testing.T) {
	f := New()
	f.Write("a", "x")
	s1, _ := f.Stamp("a")
	f.Touch("a")
	s2, _ := f.Stamp("a")
	if s2 <= s1 {
		t.Error("stamp not updated")
	}
	if c, _ := f.Read("a"); c != "x" {
		t.Error("content changed")
	}
}

func TestGenerated(t *testing.T) {
	f := New()
	for _, p := range []string{"out/b", "out/a", StateFile, "src/x", "outx"} {
		f.Write(p, "")
	}
	if got, want := f.Generated(), []string{StateFile, "out/a", "out/b"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Generated = %v, want %v", got, want)
	}
}

func TestLoadAndWriteDir(t *testing.T) {
	in := t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(in, "src", "sub"), 0o755))
	must(os.WriteFile(filepath.Join(in, "session.txt"), []byte("build\n"), 0o644))
	must(os.WriteFile(filepath.Join(in, "main.kiln"), []byte("x"), 0o644))
	must(os.WriteFile(filepath.Join(in, "src", "sub", "a.txt"), []byte("A"), 0o644))
	f, err := LoadDir(in, "session.txt")
	must(err)
	if got, want := f.Paths(), []string{"main.kiln", "src/sub/a.txt"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Paths = %v, want %v", got, want)
	}
	out := t.TempDir()
	must(f.WriteDir(out))
	b, err := os.ReadFile(filepath.Join(out, "src", "sub", "a.txt"))
	must(err)
	if string(b) != "A" {
		t.Errorf("content %q", b)
	}
}
