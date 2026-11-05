package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	cases := map[string]string{
		"c x\np cnf 3 2\n1 -2 0\n2 3 0\n":            "SAT\n",
		"p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n": "UNSAT\n",
		"p cnf 0 0\n": "SAT\n0\n",
	}
	for in, want := range cases {
		var out bytes.Buffer
		if err := run(strings.NewReader(in), &out); err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(out.String(), want) {
			t.Errorf("input %q: got %q want prefix %q", in, out.String(), want)
		}
	}
}

func TestRunBadInput(t *testing.T) {
	if err := run(strings.NewReader("1 0\n"), &bytes.Buffer{}); err == nil {
		t.Fatal("expected error")
	}
}
