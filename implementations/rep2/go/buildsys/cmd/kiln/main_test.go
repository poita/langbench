package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	put := func(rel, data string) {
		p := filepath.Join(in, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("session.txt", "build\nbuild\n")
	put("main.kiln", "step {\n    out \"out/x.txt\"\n    in \"src/s.txt\"\n    cmd upper()\n}\ndefault \"out/x.txt\"\n")
	put("src/s.txt", "hi\n")
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	log, err := os.ReadFile(filepath.Join(out, "log.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := "step 1: build (default) -j 1\n  run 0 2 w0 out/x.txt upper()\n  ok ran=1 hit=0 time=2\n" +
		"step 2: build (default) -j 1\n  hit 0 out/x.txt\n  ok ran=0 hit=1 time=0\n"
	if string(log) != want {
		t.Errorf("log = %q", log)
	}
	got, err := os.ReadFile(filepath.Join(out, "workspace", "out", "x.txt"))
	if err != nil || string(got) != "HI\n" {
		t.Errorf("output file = %q, %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(out, "workspace", "session.txt")); err == nil {
		t.Error("session.txt must not be part of the workspace")
	}
	if _, err := os.Stat(filepath.Join(out, "workspace", ".kiln-state")); err != nil {
		t.Error("state file missing from workspace")
	}
}

func TestRunMissingSession(t *testing.T) {
	if err := run(t.TempDir(), t.TempDir()); err == nil {
		t.Error("expected an error without session.txt")
	}
}
