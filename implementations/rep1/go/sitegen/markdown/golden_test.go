package markdown

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestGolden converts every testdata/*.md file and compares the result with
// the matching .html file, which was produced by cmark 0.31.2.
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("testdata/*.md")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden files found: %v", err)
	}
	for _, md := range files {
		name := strings.TrimSuffix(filepath.Base(md), ".md")
		if name == "README" {
			continue
		}
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(md)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(md, ".md") + ".html")
			if err != nil {
				t.Fatal(err)
			}
			if got := ToHTML(string(src)); got != string(want) {
				t.Errorf("mismatch\n--- input\n%s\n--- want\n%s\n--- got\n%s", src, want, got)
			}
		})
	}
}
