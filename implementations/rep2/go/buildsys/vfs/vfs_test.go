package vfs

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestHashVectors(t *testing.T) {
	cases := map[string]string{
		"":        "cbf29ce484222325",
		"hello\n": "a9bc80cca21f28b3",
		"abc\n":   "fc17b183ee074373",
	}
	for in, want := range cases {
		if got := HashHex(Hash([]byte(in))); got != want {
			t.Errorf("Hash(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseHashHex(t *testing.T) {
	if h, ok := ParseHashHex("a9bc80cca21f28b3"); !ok || h != Hash([]byte("hello\n")) {
		t.Errorf("round trip failed: %x %v", h, ok)
	}
	for _, bad := range []string{"", "A9BC80CCA21F28B3", "a9bc80cca21f28b", "a9bc80cca21f28b3 ", "g9bc80cca21f28b3"} {
		if _, ok := ParseHashHex(bad); ok {
			t.Errorf("ParseHashHex(%q) accepted", bad)
		}
	}
}

func TestValidPath(t *testing.T) {
	good := []string{"a", "src/a.txt", "a/b/c", ".kiln-state", "x+y_z-1.2", "..a", "a..", "out/.hidden"}
	bad := []string{"", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "a?", "a[", "é", "a\\b"}
	for _, p := range good {
		if !ValidPath(p) {
			t.Errorf("ValidPath(%q) = false", p)
		}
	}
	for _, p := range bad {
		if ValidPath(p) {
			t.Errorf("ValidPath(%q) = true", p)
		}
	}
	long := make([]byte, 256)
	for i := range long {
		long[i] = 'a'
	}
	if ValidPath(string(long)) || !ValidPath(string(long[:255])) {
		t.Error("component length limit is 255")
	}
}

func TestIsIdent(t *testing.T) {
	for s, want := range map[string]bool{"all": true, "_x1": true, "": false, "1a": false, "a-b": false} {
		if IsIdent(s) != want {
			t.Errorf("IsIdent(%q) != %v", s, want)
		}
	}
}

func TestReadWriteHashCache(t *testing.T) {
	fs := New()
	fs.Write("a", []byte("hello\n"))
	h, ok := fs.Hash("a")
	if !ok || HashHex(h) != "a9bc80cca21f28b3" {
		t.Fatalf("hash = %x %v", h, ok)
	}
	fs.Write("a", []byte("abc\n"))
	if h, _ := fs.Hash("a"); HashHex(h) != "fc17b183ee074373" {
		t.Error("hash not invalidated by Write")
	}
	fs.WriteHashed("b", []byte("x"), 42)
	if h, _ := fs.Hash("b"); h != 42 {
		t.Error("WriteHashed ignored")
	}
	fs.Touch("a")
	if d, _ := fs.Read("a"); string(d) != "abc\n" {
		t.Error("Touch changed content")
	}
	if !fs.Delete("a") || fs.Delete("a") || fs.Exists("a") {
		t.Error("Delete misbehaves")
	}
}

func TestGlobCandidatesAndGenerated(t *testing.T) {
	fs := New()
	for _, p := range []string{"src/a.txt", "src/b.txt", "srcx", "src", "out/x", ".kiln-state", "z"} {
		fs.Write(p, nil)
	}
	got := fs.GlobCandidates("src")
	if want := []string{"src", "src/a.txt", "src/b.txt", "srcx"}; !reflect.DeepEqual(got, want) {
		t.Errorf("candidates = %v, want %v", got, want)
	}
	if got := fs.GlobCandidates(""); len(got) != 5 {
		t.Errorf("all candidates = %v (out/ and .kiln-state must be excluded)", got)
	}
	fs.Write("src/c.txt", nil)
	fs.Delete("src/a.txt")
	if got := fs.GlobCandidates("src/"); !reflect.DeepEqual(got, []string{"src/b.txt", "src/c.txt"}) {
		t.Errorf("index not refreshed: %v", got)
	}
	if got := fs.Generated(); !reflect.DeepEqual(got, []string{".kiln-state", "out/x"}) {
		t.Errorf("Generated = %v", got)
	}
}

func TestDiskRoundTrip(t *testing.T) {
	in := t.TempDir()
	os.MkdirAll(filepath.Join(in, "d/e"), 0o755)
	os.WriteFile(filepath.Join(in, "session.txt"), []byte("build\n"), 0o644)
	os.WriteFile(filepath.Join(in, "d/e/f.txt"), []byte("data"), 0o644)
	os.WriteFile(filepath.Join(in, ".kiln-state"), []byte("x"), 0o644)
	fs, err := LoadDir(in, "session.txt")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{".kiln-state", "d/e/f.txt"}; !reflect.DeepEqual(fs.Paths(), want) {
		t.Fatalf("paths = %v", fs.Paths())
	}
	out := filepath.Join(t.TempDir(), "ws")
	if err := fs.WriteDir(out); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(out, "d/e/f.txt")); err != nil || string(b) != "data" {
		t.Errorf("written file = %q, %v", b, err)
	}
}
