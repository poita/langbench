package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "p cnf 0 0\n", "SAT\n0\n"},
		{"unsat", "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0", "UNSAT\n"},
		{"empty clause", "p cnf 1 1\n0\n", "UNSAT\n"},
		{"free vars", "p cnf 3 1\n1 -1 0\n", "SAT\n-1 -2 -3 0\n"},
		{"forced", "p cnf 3 2\n-1 0\n2 0\n", "SAT\n-1 2 -3 0\n"},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		if err := run(strings.NewReader(tc.in), &out); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if out.String() != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, out.String(), tc.want)
		}
	}
}

func TestRunMalformed(t *testing.T) {
	if err := run(strings.NewReader("1 0\n"), &bytes.Buffer{}); err == nil {
		t.Fatal("expected error")
	}
}
