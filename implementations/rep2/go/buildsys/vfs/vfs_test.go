package vfs

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestHash(t *testing.T) {
	tests := map[string]string{
		"":        "cbf29ce484222325",
		"hello\n": "a9bc80cca21f28b3",
		"abc\n":   "fc17b183ee074373",
	}
	for in, want := range tests {
		if got := HashString(Hash(in)); got != want {
			t.Errorf("Hash(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseHash(t *testing.T) {
	if h, ok := ParseHash("cbf29ce484222325"); !ok || h != 0xcbf29ce484222325 {
		t.Errorf("ParseHash failed: %x %v", h, ok)
	}
	for _, bad := range []string{"", "CBF29CE484222325", "cbf29ce48422232", "cbf29ce4842223250", "zbf29ce484222325"} {
		if _, ok := ParseHash(bad); ok {
			t.Errorf("ParseHash(%q) accepted", bad)
		}
	}
}

func TestValidPath(t *testing.T) {
	good := []string{"a", "src/a.txt", "a/b/c", ".kiln-state", "x+y-z_1", "..a", "a.."}
	bad := []string{"", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "a?", "a[", "@a", "é"}
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
	if ValidPath(string(long)) {
		t.Error("256-byte component accepted")
	}
}

func TestWritePrefixIndexAndClean(t *testing.T) {
	v := New()
	for _, p := range []string{"src/b.txt", "src/a.txt", "out/x", "srcx", ".kiln-state", "lib"} {
		v.Write(p, p)
	}
	if got, want := v.WithPrefix("src/"), []string{"src/a.txt", "src/b.txt"}; !reflect.DeepEqual(got, want) {
		t.Errorf("WithPrefix(src/) = %v, want %v", got, want)
	}
	if got := v.WithPrefix("out"); len(got) != 0 {
		t.Errorf("generated paths must not be indexed, got %v", got)
	}
	v.Delete("src/a.txt")
	if got, want := v.WithPrefix("src"), []string{"src/b.txt", "srcx"}; !reflect.DeepEqual(got, want) {
		t.Errorf("after delete WithPrefix(src) = %v, want %v", got, want)
	}
	removed := v.Clean()
	if want := []string{".kiln-state", "out/x"}; !reflect.DeepEqual(removed, want) {
		t.Errorf("Clean() = %v, want %v", removed, want)
	}
	if v.Exists("out/x") || !v.Exists("lib") {
		t.Error("Clean removed the wrong files")
	}
}

func TestHashCachedPerContent(t *testing.T) {
	v := New()
	v.Write("a", "hello\n")
	f := v.Get("a")
	v.Write("a", "other")
	if got := HashString(f.Hash()); got != "a9bc80cca21f28b3" {
		t.Errorf("old snapshot hash changed: %s", got)
	}
	if v.Get("a").Content() != "other" {
		t.Error("write did not replace content")
	}
}

func TestLoadExport(t *testing.T) {
	dir := t.TempDir()
	write := func(rel, data string) {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("session.txt", "build\n")
	write("main.kiln", "x")
	write("src/a.txt", "a")
	v, err := Load(dir, func(rel string) bool { return rel == "session.txt" })
	if err != nil {
		t.Fatal(err)
	}
	if got, want := v.Paths(), []string{"main.kiln", "src/a.txt"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Paths() = %v, want %v", got, want)
	}
	outDir := t.TempDir()
	if err := v.Export(outDir); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(outDir, "src", "a.txt"))
	if err != nil || string(data) != "a" {
		t.Errorf("exported file = %q, %v", data, err)
	}
}
