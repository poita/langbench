package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitrepo/internal/testrepo"
)

func setup(t *testing.T, commands string) (input, out string) {
	input = t.TempDir()
	r := testrepo.New(t)
	b := r.Blob("one file\n")
	tree := r.Tree(testrepo.Entry{Mode: 0o100644, Name: "only.txt", ID: b})
	c := r.Commit(tree, nil, 1400003600, "Add only.txt\n")
	r.SetRef("refs/heads/main", c)
	if err := os.Rename(r.Dir, filepath.Join(input, "repo")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(input, "commands.txt"), []byte(commands), 0o644); err != nil {
		t.Fatal(err)
	}
	return input, filepath.Join(t.TempDir(), "out")
}

func TestRunWritesOneFilePerCommand(t *testing.T) {
	input, out := setup(t, "count-objects\nbogus\nrev-parse main\nls-tree main") // no final newline
	if err := run(input, out); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != 4 {
		t.Fatalf("%d output files, want 4", len(entries))
	}
	read := func(n string) string {
		b, err := os.ReadFile(filepath.Join(out, n))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if got := read("001.out"); got != "loose: 3\nin-pack: 0\npacks: 0\n" {
		t.Errorf("001 = %q", got)
	}
	if got := read("002.out"); got != "error\n" {
		t.Errorf("002 = %q", got)
	}
	if got := read("004.out"); !strings.HasSuffix(got, "\tonly.txt\n") {
		t.Errorf("004 = %q", got)
	}
}

func TestRunNoCommandsAndTrailingNewline(t *testing.T) {
	input, out := setup(t, "")
	if err := run(input, out); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(out); len(entries) != 0 {
		t.Errorf("%d files for no commands", len(entries))
	}
	input, out = setup(t, "count-objects\n")
	run(input, out)
	if entries, _ := os.ReadDir(out); len(entries) != 1 {
		t.Errorf("%d files, want 1", len(entries))
	}
}

func TestRunMissingRepoYieldsErrors(t *testing.T) {
	input, out := setup(t, "rev-parse main\n")
	os.RemoveAll(filepath.Join(input, "repo"))
	if err := run(input, out); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(out, "001.out")); string(b) != "error\n" {
		t.Errorf("got %q", b)
	}
}

func TestFourDigitNames(t *testing.T) {
	input, out := setup(t, strings.Repeat("count-objects\n", 1001))
	if err := run(input, out); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"999.out", "1000.out", "1001.out"} {
		if _, err := os.Stat(filepath.Join(out, n)); err != nil {
			t.Error(err)
		}
	}
}
