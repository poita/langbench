package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	cases := map[string]string{
		"p cnf 0 0\n": "SAT\n0\n",
		"p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n": "UNSAT\n",
		"p cnf 2 1\n1 0\n":                           "SAT\n1 -2 0\n",
		"p cnf 1 1\n0\n":                             "UNSAT\n",
	}
	for in, want := range cases {
		var out bytes.Buffer
		if err := run(strings.NewReader(in), &out); err != nil {
			t.Fatal(err)
		}
		if out.String() != want {
			t.Errorf("input %q: got %q want %q", in, out.String(), want)
		}
	}
}

func TestRunBadInput(t *testing.T) {
	if err := run(strings.NewReader("garbage"), &bytes.Buffer{}); err == nil {
		t.Fatal("expected error")
	}
}
