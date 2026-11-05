package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunWritesOneFilePerCommand(t *testing.T) {
	in := t.TempDir()
	if err := os.MkdirAll(filepath.Join(in, "repo", "objects"), 0o755); err != nil {
		t.Fatal(err)
	}
	// No trailing newline on the last line, and a bad command in the middle.
	cmds := "count-objects\nbogus\nrev-parse HEAD\nrev-parse  HEAD"
	os.WriteFile(filepath.Join(in, "commands.txt"), []byte(cmds), 0o644)
	out := filepath.Join(t.TempDir(), "out")
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"001.out": "loose: 0\nin-pack: 0\npacks: 0\n",
		"002.out": "error\n",
		"003.out": "error\n",
		"004.out": "error\n",
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != len(want) {
		t.Fatalf("%d files written, want %d", len(entries), len(want))
	}
	for name, w := range want {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil || string(got) != w {
			t.Errorf("%s = %q, %v; want %q", name, got, err, w)
		}
	}
}

func TestMissingRepositoryFailsEveryCommand(t *testing.T) {
	in := t.TempDir()
	os.WriteFile(filepath.Join(in, "commands.txt"), []byte("count-objects\n"), 0o644)
	out := t.TempDir()
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(out, "001.out"))
	if string(got) != "error\n" {
		t.Errorf("got %q", got)
	}
}
