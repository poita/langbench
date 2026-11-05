package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunWritesOneFilePerQuery(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	// An unreadable database turns every query into an error, still exit 0.
	if err := os.WriteFile(filepath.Join(in, "x.sqlite"), []byte("junk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(in, "queries.txt"), []byte(".tables\nCOUNT t"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"001.txt", "002.txt"} {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil || string(got) != "error\n" {
			t.Errorf("%s = %q, %v", name, got, err)
		}
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != 2 {
		t.Errorf("want 2 output files, got %d", len(entries))
	}
}

func TestFindDatabaseMissing(t *testing.T) {
	if _, err := findDatabase(t.TempDir()); err == nil {
		t.Error("expected an error when no .sqlite file exists")
	}
}
