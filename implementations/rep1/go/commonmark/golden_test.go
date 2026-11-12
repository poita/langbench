package commonmark_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"example.com/commonmark"
)

// normalize mirrors the comparison used by the project's test runner:
// trailing whitespace on each line and trailing newlines are ignored.
func normalize(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

func TestGolden(t *testing.T) {
	inputs, err := filepath.Glob("testdata/golden/*.in")
	if err != nil || len(inputs) == 0 {
		t.Fatalf("no golden inputs found (err=%v)", err)
	}
	for _, in := range inputs {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			if got := commonmark.ToHTML(string(src)); normalize(got) != normalize(string(want)) {
				t.Errorf("output differs from %s.out\n got: %q\nwant: %q", name, got, want)
			}
		})
	}
}
