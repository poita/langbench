package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	in, out := t.TempDir(), filepath.Join(t.TempDir(), "out")
	if err := os.WriteFile(filepath.Join(in, "commands.txt"), []byte("put \"a\" 1\nget \"a\""), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	res, err := os.ReadFile(filepath.Join(out, "results.txt"))
	if err != nil || string(res) != "[1] ok put created\n[2] ok get value\n  1\n" {
		t.Fatalf("results %q, %v", res, err)
	}
	for name, size := range map[string]int{"main.tdb": 1024, "main.twal": 32 + 2*1048 + 24} {
		fi, err := os.Stat(filepath.Join(out, name))
		if err != nil || fi.Size() != int64(size) {
			t.Errorf("%s: %v %v", name, fi, err)
		}
	}
	// A second run on the produced files continues from them.
	if err := os.WriteFile(filepath.Join(out, "commands.txt"), []byte("stat"), 0o644); err != nil {
		t.Fatal(err)
	}
	out2 := filepath.Join(t.TempDir(), "out2")
	if err := run(out, out2); err != nil {
		t.Fatal(err)
	}
	res, _ = os.ReadFile(filepath.Join(out2, "results.txt"))
	if len(res) == 0 || string(res[:11]) != "[1] ok stat" {
		t.Fatalf("second run results %q", res)
	}
}

func TestMissingCommands(t *testing.T) {
	if err := run(t.TempDir(), t.TempDir()); err == nil {
		t.Fatal("expected an error for a missing commands.txt")
	}
}
