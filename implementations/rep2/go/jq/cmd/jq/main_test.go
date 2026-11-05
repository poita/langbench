package main

import (
	"bytes"
	"strings"
	"testing"
)

func runCLI(input string) (string, int) {
	var out, errb bytes.Buffer
	code := run(strings.NewReader(input), &out, &errb)
	return out.String(), code
}

func TestSplitsFilterAndDocument(t *testing.T) {
	out, code := runCLI(".users | map(.n)\n{\"users\":[{\"n\":1},\n{\"n\":2}]}\n")
	if code != 0 || out != "[1,2]\n" {
		t.Errorf("got %q code %d", out, code)
	}
}

func TestErrorAfterPartialOutput(t *testing.T) {
	out, code := runCLI("1, 2, error, 3\nnull")
	if code != 0 || out != "1\n2\nerror\n" {
		t.Errorf("got %q code %d", out, code)
	}
}

func TestNoOutput(t *testing.T) {
	out, code := runCLI("empty\n[]")
	if code != 0 || out != "" {
		t.Errorf("got %q code %d", out, code)
	}
}

func TestBadFilterOrDocument(t *testing.T) {
	if _, code := runCLI(".[\nnull"); code == 0 {
		t.Error("bad filter should fail")
	}
	if _, code := runCLI(".\n{"); code == 0 {
		t.Error("bad document should fail")
	}
}
