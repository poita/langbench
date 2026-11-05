package vfs_test

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"buildsys/vfs"
)

func TestHash64(t *testing.T) {
	cases := map[string]string{
		"":        "cbf29ce484222325",
		"hello\n": "a9bc80cca21f28b3",
		"abc\n":   "fc17b183ee074373",
	}
	for in, want := range cases {
		if got := vfs.HashHex(vfs.Hash64([]byte(in))); got != want {
			t.Errorf("hash(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseHashHex(t *testing.T) {
	h, ok := vfs.ParseHashHex("a9bc80cca21f28b3")
	if !ok || h != vfs.Hash64([]byte("hello\n")) {
		t.Fatalf("round trip failed: %x %v", h, ok)
	}
	for _, bad := range []string{"", "A9BC80CCA21F28B3", "a9bc80cca21f28b", "a9bc80cca21f28b33", "g9bc80cca21f28b3"} {
		if _, ok := vfs.ParseHashHex(bad); ok {
			t.Errorf("ParseHashHex(%q) accepted", bad)
		}
	}
}

func TestIsPath(t *testing.T) {
	good := []string{"a", "src/a.txt", "out/x_y+z-1", "a/.hidden", "...", "a/b/c/d"}
	bad := []string{"", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "a@b", "é",
		strings.Repeat("a", 256), strings.Repeat("a/", 600)}
	for _, p := range good {
		if !vfs.IsPath(p) {
			t.Errorf("IsPath(%q) = false", p)
		}
	}
	for _, p := range bad {
		if vfs.IsPath(p) {
			t.Errorf("IsPath(%q) = true", p)
		}
	}
	if !vfs.IsPath(strings.Repeat("a", 255)) {
		t.Error("255-byte component rejected")
	}
}

func TestGenerated(t *testing.T) {
	for p, want := range map[string]bool{"out": true, "out/a": true, "outx/a": false, "src/out/a": false, "outer": false} {
		if got := vfs.IsGenerated(p); got != want {
			t.Errorf("IsGenerated(%q) = %v", p, got)
		}
	}
	if vfs.GlobEligible(".kiln-state") || vfs.GlobEligible("out/a") || !vfs.GlobEligible("src/a") {
		t.Error("GlobEligible wrong")
	}
}

func TestReadWriteHashCache(t *testing.T) {
	fs := vfs.New()
	fs.Write("a", []byte("hello\n"))
	h, ok := fs.Hash("a")
	if !ok || vfs.HashHex(h) != "a9bc80cca21f28b3" {
		t.Fatalf("hash = %x", h)
	}
	fs.Write("a", []byte("abc\n"))
	if h, _ := fs.Hash("a"); vfs.HashHex(h) != "fc17b183ee074373" {
		t.Error("hash not invalidated by Write")
	}
	if _, ok := fs.Hash("missing"); ok {
		t.Error("hash of missing file")
	}
	fs.WriteHashed("b", []byte("x"), 42)
	if h, _ := fs.Hash("b"); h != 42 {
		t.Error("WriteHashed hash not used")
	}
	if !fs.Delete("a") || fs.Delete("a") || fs.Exists("a") {
		t.Error("Delete misbehaves")
	}
}

func TestTouchOnlyChangesStamp(t *testing.T) {
	fs := vfs.New()
	fs.Write("a", []byte("x"))
	fs.Write("b", []byte("y"))
	s1, _ := fs.Stamp("a")
	fs.Touch("a")
	s2, _ := fs.Stamp("a")
	sb, _ := fs.Stamp("b")
	if s2 <= s1 || s2 <= sb {
		t.Errorf("stamps: %d %d %d", s1, s2, sb)
	}
	c, _ := fs.Read("a")
	if string(c) != "x" {
		t.Error("content changed")
	}
}

func TestCandidates(t *testing.T) {
	fs := vfs.New()
	for _, p := range []string{"src/b", "src/a", "srcx", "src", "other", "out/gen", ".kiln-state", "src/sub/c"} {
		fs.Write(p, nil)
	}
	got := fs.Candidates("src")
	want := []string{"src", "src/a", "src/b", "src/sub/c", "srcx"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Candidates(src) = %v", got)
	}
	if n := len(fs.Candidates("")); n != 6 {
		t.Errorf("all candidates = %d", n)
	}
	fs.Write("src/0", nil)
	fs.Delete("srcx")
	got = fs.Candidates("src/")
	if !reflect.DeepEqual(got, []string{"src/0", "src/a", "src/b", "src/sub/c"}) {
		t.Fatalf("after mutation: %v", got)
	}
}

func TestPaths(t *testing.T) {
	fs := vfs.New()
	fs.Write("b", nil)
	fs.Write("a/z", nil)
	fs.Write("out/q", nil)
	if got := fs.Paths(); !reflect.DeepEqual(got, []string{"a/z", "b", "out/q"}) {
		t.Fatal(got)
	}
	if fs.Len() != 3 {
		t.Fatal("Len")
	}
}

func TestDiskRoundTrip(t *testing.T) {
	in := t.TempDir()
	write := func(rel, content string) {
		full := filepath.Join(in, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("session.txt", "build\n")
	write("main.kiln", "x")
	write("src/deep/a.txt", "a\x00b")
	write(".kiln-state", "kiln-state 1\n")

	fs := vfs.New()
	if err := fs.LoadDir(in, func(rel string) bool { return rel == "session.txt" }); err != nil {
		t.Fatal(err)
	}
	if got := fs.Paths(); !reflect.DeepEqual(got, []string{".kiln-state", "main.kiln", "src/deep/a.txt"}) {
		t.Fatalf("loaded %v", got)
	}
	out := filepath.Join(t.TempDir(), "workspace")
	if err := fs.WriteDir(out); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(out, "src", "deep", "a.txt"))
	if err != nil || string(b) != "a\x00b" {
		t.Fatalf("written file: %q %v", b, err)
	}
}
