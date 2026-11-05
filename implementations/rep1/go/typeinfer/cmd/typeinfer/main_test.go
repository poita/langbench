package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	var out, errw bytes.Buffer
	in := strings.NewReader("let id x = x;;\nid 1;;\nfun x -> x x;;\nnope;;\n")
	if err := run(in, &out, &errw); err != nil {
		t.Fatal(err)
	}
	want := "id : 'a -> 'a\n- : int\nerror: occurs\nerror: unbound\n"
	if out.String() != want {
		t.Errorf("stdout = %q, want %q", out.String(), want)
	}
	if errw.Len() != 0 {
		t.Errorf("stderr = %q", errw.String())
	}
}

func TestRunEmpty(t *testing.T) {
	var out, errw bytes.Buffer
	if err := run(strings.NewReader(""), &out, &errw); err != nil || out.Len() != 0 {
		t.Errorf("out=%q err=%v", out.String(), err)
	}
}

func TestRunSyntaxErrorGoesToStderr(t *testing.T) {
	var out, errw bytes.Buffer
	if err := run(strings.NewReader("let a = 1;; let = ;;"), &out, &errw); err != nil {
		t.Fatal(err)
	}
	if out.String() != "a : int\n" || !strings.Contains(errw.String(), "syntax error") {
		t.Errorf("out=%q err=%q", out.String(), errw.String())
	}
}
