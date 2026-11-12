package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	in := t.TempDir()
	out := t.TempDir()
	db, err := os.ReadFile("../../testdata/mini.sqlite")
	if err != nil {
		t.Fatal(err)
	}
	must(t, os.WriteFile(filepath.Join(in, "mini.sqlite"), db, 0o644))
	// No trailing newline on the last line.
	must(t, os.WriteFile(filepath.Join(in, "queries.txt"),
		[]byte(".tables\nSELECT name FROM people WHERE age IS NULL\nSELECT nope FROM people\nSELECT name FROM people WHERE age > 99\nCOUNT people"), 0o644))

	must(t, run(in, out))

	want := map[string]string{
		"001.txt": "kv\npeople\nseq\n",
		"002.txt": "Alan\n",
		"003.txt": "error\n",
		"004.txt": "",
		"005.txt": "4\n",
	}
	entries, err := os.ReadDir(out)
	must(t, err)
	if len(entries) != len(want) {
		t.Errorf("wrote %d files, want %d", len(entries), len(want))
	}
	for name, content := range want {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if string(got) != content {
			t.Errorf("%s = %q, want %q", name, got, content)
		}
	}
}

func TestRunBadDatabase(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	must(t, os.WriteFile(filepath.Join(in, "x.sqlite"), []byte("garbage"), 0o644))
	must(t, os.WriteFile(filepath.Join(in, "queries.txt"), []byte(".tables\nCOUNT t\n"), 0o644))
	must(t, run(in, out))
	for _, n := range []string{"001.txt", "002.txt"} {
		got, _ := os.ReadFile(filepath.Join(out, n))
		if string(got) != "error\n" {
			t.Errorf("%s = %q, want error", n, got)
		}
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
