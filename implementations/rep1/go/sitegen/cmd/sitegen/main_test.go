package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	out := filepath.Join(t.TempDir(), "public") // does not exist yet
	var stderr bytes.Buffer
	if code := run([]string{"../../testdata/pond", out}, &stderr); code != 0 {
		t.Fatalf("exit code %d: %s", code, stderr.String())
	}
	for _, name := range []string{"index.html", "page/2/index.html", "posts/ducks/index.html", "feed.xml", "sitemap.xml", "robots.txt"} {
		if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(name))); err != nil {
			t.Errorf("missing output %s: %v", name, err)
		}
	}
}

func TestRunUsage(t *testing.T) {
	var stderr bytes.Buffer
	if code := run([]string{"only-one"}, &stderr); code != 2 || !strings.Contains(stderr.String(), "usage") {
		t.Errorf("code %d, stderr %q", code, stderr.String())
	}
}

func TestRunBadInput(t *testing.T) {
	var stderr bytes.Buffer
	if code := run([]string{t.TempDir(), t.TempDir()}, &stderr); code != 1 {
		t.Errorf("code %d, want 1", code)
	}
}
