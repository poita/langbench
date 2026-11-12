package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	cases := []struct{ name, in, out string }{
		{"answers", "p(2). p(1). ?- p(X).", "p(1)\np(2)\n-- 2\n"},
		{"no queries", "p(1).", ""},
		{"unsafe", "q(1). ?- q(X). p(X) :- q(Y).", "error\n"},
		{"unstratifiable", "w(X) :- e(X, Y), not w(Y).", "error\n"},
		{"syntax", "p(", "error\n"},
	}
	for _, c := range cases {
		var out, errb bytes.Buffer
		if code := run(strings.NewReader(c.in), &out, &errb); code != 0 {
			t.Errorf("%s: exit %d", c.name, code)
		}
		if out.String() != c.out {
			t.Errorf("%s: got %q, want %q", c.name, out.String(), c.out)
		}
	}
}
