package main

import (
	"bytes"
	"strings"
	"testing"
)

func runCLI(t *testing.T, stdin string) (string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := run(strings.NewReader(stdin), &out, &errOut)
	return out.String(), code
}

func TestCLIOutputs(t *testing.T) {
	out, code := runCLI(t, ".[] | . * 2\n[1,\n 2]\n")
	if out != "2\n4\n" || code != 0 {
		t.Errorf("got %q, %d", out, code)
	}
}

func TestCLIErrorLineAfterResults(t *testing.T) {
	out, code := runCLI(t, "1, error, 2\nnull")
	if out != "1\nerror\n" || code != 0 {
		t.Errorf("got %q, %d", out, code)
	}
}

func TestCLINoOutput(t *testing.T) {
	out, code := runCLI(t, "empty\nnull")
	if out != "" || code != 0 {
		t.Errorf("got %q, %d", out, code)
	}
}

func TestCLIDocumentOnlyAfterFirstNewline(t *testing.T) {
	out, _ := runCLI(t, "length\n\n\n\"abc\"\n")
	if out != "3\n" {
		t.Errorf("got %q", out)
	}
}

func TestCLIBadInput(t *testing.T) {
	if _, code := runCLI(t, ".[\nnull"); code == 0 {
		t.Error("bad filter should fail")
	}
	if _, code := runCLI(t, ".\n{"); code == 0 {
		t.Error("bad document should fail")
	}
}
