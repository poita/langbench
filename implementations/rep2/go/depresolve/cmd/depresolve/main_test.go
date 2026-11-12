package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"empty root", "root:\n", ""},
		{"resolved", "b 1.0.0:\na 1.0.0: b ^1.0.0\nroot: a *\n", "a 1.0.0\nb 1.0.0\n"},
		{"unsat", "a 1.0.0:\nroot: a ^2.0.0\n", "unsatisfiable\n"},
	}
	for _, c := range cases {
		var out bytes.Buffer
		if err := run(strings.NewReader(c.in), &out); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if out.String() != c.want {
			t.Errorf("%s: got %q, want %q", c.name, out.String(), c.want)
		}
	}
}

func TestRunMalformed(t *testing.T) {
	if err := run(strings.NewReader("garbage\n"), &bytes.Buffer{}); err == nil {
		t.Error("expected error for malformed input")
	}
}
