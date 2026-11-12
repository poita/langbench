package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunExamples(t *testing.T) {
	files, _ := filepath.Glob("../../testdata/example*.in")
	if len(files) == 0 {
		t.Fatal("no example files")
	}
	for _, in := range files {
		q, _ := os.ReadFile(in)
		want, _ := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
		var out bytes.Buffer
		if err := run(bytes.NewReader(q), &out); err != nil {
			t.Fatalf("%s: %v", in, err)
		}
		if out.String() != string(want) {
			t.Errorf("%s: output mismatch", in)
		}
	}
}

func TestRunMultipleQueriesNoTrailingNewline(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("L 0 1\nH auto a b"), &out); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(out.String(), "version 1 mask"); got != 2 {
		t.Errorf("got %d symbols, want 2:\n%s", got, out.String())
	}
	if !strings.HasSuffix(out.String(), "\n\n") {
		t.Error("output must end with an empty line")
	}
}

func TestParseQuery(t *testing.T) {
	_, m, text, err := parseQuery("Q 3 hello world")
	if err != nil || m != 3 || text != "hello world" {
		t.Errorf("got mask %d text %q err %v", m, text, err)
	}
	for _, bad := range []string{"X 0 a", "L 9 a", "L auto", "L  a", "L", "L 0a b"} {
		if _, _, _, err := parseQuery(bad); err == nil {
			t.Errorf("parseQuery(%q): expected error", bad)
		}
	}
}
