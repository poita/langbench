package main

import (
	"bytes"
	"strings"
	"testing"
)

func runCLI(src string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	code = run(strings.NewReader(src), &out, &errb)
	return code, out.String(), errb.String()
}

func TestAnswers(t *testing.T) {
	code, out, _ := runCLI("p(b). p(a). p(1).\n?- p(X).\n")
	if code != 0 || out != "p(1)\np(a)\np(b)\n-- 3\n" {
		t.Errorf("code %d out %q", code, out)
	}
}

func TestNoQueriesNoOutput(t *testing.T) {
	code, out, _ := runCLI("p(1).")
	if code != 0 || out != "" {
		t.Errorf("code %d out %q", code, out)
	}
}

func TestErrorsPrintError(t *testing.T) {
	for _, src := range []string{
		"p(X) :- q(Y).\n?- p(X).",
		"w(X) :- e(X, Y), not w(Y).\n?- w(X).",
	} {
		code, out, _ := runCLI(src)
		if code != 0 || out != "error\n" {
			t.Errorf("%q: code %d out %q", src, code, out)
		}
	}
}

func TestSyntaxErrorExitsNonzero(t *testing.T) {
	code, out, errs := runCLI("p(")
	if code == 0 || out != "" || errs == "" {
		t.Errorf("code %d out %q err %q", code, out, errs)
	}
}
