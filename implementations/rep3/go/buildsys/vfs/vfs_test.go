package vfs

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestHash64(t *testing.T) {
	cases := map[string]string{
		"":        "cbf29ce484222325",
		"hello\n": "a9bc80cca21f28b3",
		"abc\n":   "fc17b183ee074373",
	}
	for in, want := range cases {
		if got := HexHash(Hash64([]byte(in))); got != want {
			t.Errorf("hash(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseHexHash(t *testing.T) {
	h, ok := ParseHexHash("a9bc80cca21f28b3")
	if !ok || h != Hash64([]byte("hello\n")) {
		t.Fatalf("got %x %v", h, ok)
	}
	for _, bad := range []string{"", "A9bc80cca21f28b3", "a9bc80cca21f28b", "a9bc80cca21f28b3 ", "g9bc80cca21f28b3"} {
		if _, ok := ParseHexHash(bad); ok {
			t.Errorf("ParseHexHash(%q) accepted", bad)
		}
	}
}

func TestIsWorkspacePath(t *testing.T) {
	good := []string{"a", "src/a.txt", "a/b/c", ".kiln-state", "x+y-z_1.2", "...", "out/a"}
	bad := []string{"", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "a@", "é",
		strings.Repeat("a", 256), strings.Repeat("a/", 600)}
	for _, p := range good {
		if !IsWorkspacePath(p) {
			t.Errorf("%q should be valid", p)
		}
	}
	for _, p := range bad {
		if IsWorkspacePath(p) {
			t.Errorf("%q should be invalid", p)
		}
	}
	if !IsWorkspacePath(strings.Repeat("a", 255)) {
		t.Error("255-byte component should be valid")
	}
}

func TestGenerated(t *testing.T) {
	if !IsGenerated("out") || !IsGenerated("out/x") || IsGenerated("outx/y") || IsGenerated("src/out") {
		t.Error("IsGenerated misclassifies")
	}
	if GlobEligible(".kiln-state") || GlobEligible("out/a") || !GlobEligible("src/a") {
		t.Error("GlobEligible misclassifies")
	}
}

func TestReadWriteHashCache(t *testing.T) {
	f := New()
	f.Write("a", []byte("hello\n"))
	h1, _ := f.Hash("a")
	if HexHash(h1) != "a9bc80cca21f28b3" {
		t.Fatalf("bad hash %x", h1)
	}
	f.Write("a", []byte("abc\n"))
	h2, _ := f.Hash("a")
	if HexHash(h2) != "fc17b183ee074373" {
		t.Fatalf("hash not invalidated: %x", h2)
	}
	if _, ok := f.Hash("nope"); ok {
		t.Error("hash of missing file")
	}
	if !f.Delete("a") || f.Delete("a") || f.Exists("a") {
		t.Error("delete misbehaves")
	}
}

func TestTouchOnlyChangesStamp(t *testing.T) {
	f := New()
	f.Write("a", []byte("x"))
	s := f.Stamp("a")
	f.Touch("a")
	if f.Stamp("a") <= s {
		t.Error("stamp did not advance")
	}
	if c, _ := f.Read("a"); string(c) != "x" {
		t.Error("touch changed content")
	}
}

func TestCandidates(t *testing.T) {
	f := New()
	for _, p := range []string{"src/a", "src/b/c", "srcx", "src", "out/x", ".kiln-state", "z", "a"} {
		f.Write(p, nil)
	}
	got := f.Candidates("src")
	want := []string{"src", "src/a", "src/b/c", "srcx"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if got := f.Candidates(""); len(got) != 6 {
		t.Fatalf("all eligible: %v", got)
	}
	f.Write("src/aa", nil)
	f.Delete("src/b/c")
	got = f.Candidates("src/")
	if !reflect.DeepEqual(got, []string{"src/a", "src/aa"}) {
		t.Fatalf("index not refreshed: %v", got)
	}
	if got := f.Candidates("none"); len(got) != 0 {
		t.Fatalf("unexpected %v", got)
	}
}

func TestDiskRoundTrip(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "src", "sub"), 0o755)
	os.WriteFile(filepath.Join(dir, "session.txt"), []byte("build\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "src", "sub", "a.txt"), []byte("A"), 0o644)
	os.WriteFile(filepath.Join(dir, ".kiln-state"), []byte("kiln-state 1\n"), 0o644)
	f, err := Load(dir, "session.txt")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.Paths(), []string{".kiln-state", "src/sub/a.txt"}) {
		t.Fatalf("paths %v", f.Paths())
	}
	out := filepath.Join(t.TempDir(), "o", "workspace")
	if err := f.WriteTo(out); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(out, "src", "sub", "a.txt"))
	if err != nil || string(b) != "A" {
		t.Fatalf("%q %v", b, err)
	}
}
