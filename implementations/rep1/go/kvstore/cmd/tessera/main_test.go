package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestRunWritesThreeFiles(t *testing.T) {
	in, out := t.TempDir(), filepath.Join(t.TempDir(), "out")
	if err := os.WriteFile(filepath.Join(in, "commands.txt"), []byte("put \"a\" 1\ncheckpoint\nget \"a\""), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	res, err := os.ReadFile(filepath.Join(out, "results.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := "[1] ok put created\n[2] ok checkpoint pages 2\n[3] ok get value\n  1\n"
	if string(res) != want {
		t.Errorf("results.txt = %q", res)
	}
	tdb, _ := os.ReadFile(filepath.Join(out, "main.tdb"))
	twal, _ := os.ReadFile(filepath.Join(out, "main.twal"))
	if len(tdb) != 2048 || len(twal) != 32 {
		t.Errorf("main.tdb %d bytes, main.twal %d bytes", len(tdb), len(twal))
	}

	// Feed the output back in as input: the state persists.
	in2, out2 := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(in2, "commands.txt"), []byte("scan keys\n"), 0o644)
	os.WriteFile(filepath.Join(in2, "main.tdb"), tdb, 0o644)
	os.WriteFile(filepath.Join(in2, "main.twal"), twal, 0o644)
	if err := run(in2, out2); err != nil {
		t.Fatal(err)
	}
	res2, _ := os.ReadFile(filepath.Join(out2, "results.txt"))
	if string(res2) != "[1] ok scan 1\n  \"a\"\n" {
		t.Errorf("second run results = %q", res2)
	}
	tdb2, _ := os.ReadFile(filepath.Join(out2, "main.tdb"))
	if !bytes.Equal(tdb, tdb2) {
		t.Error("main.tdb changed by a read-only script")
	}
}

func TestRunMissingCommands(t *testing.T) {
	if err := run(t.TempDir(), t.TempDir()); err == nil {
		t.Error("expected an error when commands.txt is missing")
	}
}
