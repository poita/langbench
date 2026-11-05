package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	in, out := t.TempDir(), filepath.Join(t.TempDir(), "out")
	files := map[string]string{
		"session.txt": "build\nbuild\n",
		"main.kiln":   "step {\n out \"out/a.txt\"\n cmd write(\"hi\\n\")\n}\ndefault \"out/a.txt\"\n",
	}
	for p, c := range files {
		if err := os.WriteFile(filepath.Join(in, p), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	log, _ := os.ReadFile(filepath.Join(out, "log.txt"))
	want := "step 1: build (default) -j 1\n  run 0 1 w0 out/a.txt write(\"hi\\n\")\n  ok ran=1 hit=0 time=1\n" +
		"step 2: build (default) -j 1\n  hit 0 out/a.txt\n  ok ran=0 hit=1 time=0\n"
	if string(log) != want {
		t.Errorf("log:\n%s", log)
	}
	for _, p := range []string{"workspace/main.kiln", "workspace/out/a.txt", "workspace/.kiln-state"} {
		if _, err := os.Stat(filepath.Join(out, p)); err != nil {
			t.Errorf("missing %s", p)
		}
	}
	if _, err := os.Stat(filepath.Join(out, "workspace", "session.txt")); err == nil {
		t.Error("session.txt leaked into the workspace")
	}
}

func TestRunMissingSession(t *testing.T) {
	if err := run(t.TempDir(), t.TempDir()); err == nil {
		t.Error("expected an error")
	}
}
