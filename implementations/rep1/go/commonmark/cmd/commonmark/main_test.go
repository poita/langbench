package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("# Hi\n\n- a\n- b"), &out); err != nil {
		t.Fatal(err)
	}
	want := "<h1>Hi</h1>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestRunEmpty(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader(""), &out); err != nil || out.Len() != 0 {
		t.Errorf("err=%v output=%q, want no output", err, out.String())
	}
}
