package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func normalize(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// TestGolden runs every testdata/*.in (filter line, then the document) through
// the command and compares stdout with the matching .out file.
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("../../testdata/*.in")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden tests found: %v", err)
	}
	for _, in := range files {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			input, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var stdout, stderr bytes.Buffer
			if err := run(bytes.NewReader(input), &stdout, &stderr); err != nil {
				t.Fatal(err)
			}
			if got := normalize(stdout.String()); got != normalize(string(want)) {
				t.Errorf("output mismatch\n got: %.300s\nwant: %.300s", got, want)
			}
		})
	}
}

func TestErrorLine(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if err := run(strings.NewReader("1, error, 3\nnull"), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if got := stdout.String(); got != "1\nerror\n" {
		t.Errorf("stdout = %q", got)
	}
}

func TestNoOutput(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if err := run(strings.NewReader("empty\n[1]"), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q", stdout.String())
	}
}
