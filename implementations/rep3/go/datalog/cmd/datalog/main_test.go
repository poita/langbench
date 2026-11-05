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

func TestRunAnswers(t *testing.T) {
	code, out, _ := runCLI("p(1). p(b). ?- p(X).")
	if code != 0 || out != "p(1)\np(b)\n-- 2\n" {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestRunSemanticErrorsPrintError(t *testing.T) {
	for _, src := range []string{
		"q(1). ?- q(X). p(X) :- q(Y). ?- p(X).",
		"e(1). w(X) :- e(X), not w(X). ?- w(X).",
	} {
		code, out, _ := runCLI(src)
		if code != 0 || out != "error\n" {
			t.Errorf("%q: code=%d out=%q", src, code, out)
		}
	}
}

func TestRunEmpty(t *testing.T) {
	if code, out, _ := runCLI(""); code != 0 || out != "" {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestRunSyntaxError(t *testing.T) {
	code, out, errs := runCLI("p(1")
	if code == 0 || out != "" || errs == "" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}
