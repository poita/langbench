package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ in, want string }{
		{"c example\np cnf 3 2\n1 -2 0\n2 3 0\n", ""},
		{"p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0", "UNSAT\n"},
		{"p cnf 0 0", "SAT\n0\n"},
		{"p cnf 2 1\n0\n", "UNSAT\n"},
		{"p cnf 3 1\n1 -1 0\n", "SAT\n-1 -2 -3 0\n"},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		if err := run(strings.NewReader(tc.in), &out); err != nil {
			t.Fatal(err)
		}
		got := out.String()
		if tc.want == "" { // any model of (1 ∨ ¬2) ∧ (2 ∨ 3)
			if !strings.HasPrefix(got, "SAT\n") || !strings.HasSuffix(got, " 0\n") {
				t.Errorf("unexpected output %q", got)
			}
			continue
		}
		if got != tc.want {
			t.Errorf("input %q: got %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestRunBadInput(t *testing.T) {
	if err := run(strings.NewReader("garbage"), &bytes.Buffer{}); err == nil {
		t.Error("expected an error")
	}
}
