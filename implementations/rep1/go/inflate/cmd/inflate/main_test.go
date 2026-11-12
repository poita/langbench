package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runString(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestRun(t *testing.T) {
	tests := map[string]string{
		"0300\n":         "\n",
		"":               "error\n",
		"\n":             "error\n",
		"010100feff41\n": "41\n",
		"4b4c4a862000\n": "616263616263616263\n",
		"030200\n":       "error\n",
		"  0300  \n":     "\n",
	}
	for in, want := range tests {
		if got := runString(t, in); got != want {
			t.Errorf("run(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestConformance runs the shared problem tests when they are available.
func TestConformance(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "problems", "inflate", "tests")
	ins, _ := filepath.Glob(filepath.Join(dir, "*.in"))
	if len(ins) == 0 {
		t.Skip("problem tests not found")
	}
	for _, in := range ins {
		input, err := os.ReadFile(in)
		if err != nil {
			t.Fatal(err)
		}
		want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
		if err != nil {
			t.Fatal(err)
		}
		got := runString(t, string(input))
		if strings.TrimSpace(got) != strings.TrimSpace(string(want)) {
			t.Errorf("%s: mismatch", filepath.Base(in))
		}
	}
}
