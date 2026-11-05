package main

import (
	"bytes"
	"strings"
	"testing"
)

func runString(in string) (code int, out, errOut string) {
	var o, e bytes.Buffer
	code = run(strings.NewReader(in), &o, &e)
	return code, o.String(), e.String()
}

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty root", "root:\n", ""},
		{"resolved", "b 1.0.0:\na 1.0.0: b ^1.0.0\nroot: a *\n", "a 1.0.0\nb 1.0.0\n"},
		{"unsatisfiable", "a 1.0.0:\nroot: a ^2.0.0\n", "unsatisfiable\n"},
	}
	for _, tc := range tests {
		code, out, errOut := runString(tc.in)
		if code != 0 || out != tc.want || errOut != "" {
			t.Errorf("%s: code=%d out=%q err=%q", tc.name, code, out, errOut)
		}
	}
}

func TestRunMalformed(t *testing.T) {
	code, out, errOut := runString("garbage\n")
	if code == 0 || out != "" || errOut == "" {
		t.Errorf("code=%d out=%q err=%q", code, out, errOut)
	}
}
