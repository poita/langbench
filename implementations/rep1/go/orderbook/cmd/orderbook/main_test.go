package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	var out bytes.Buffer
	in := "3\nLIMIT a BUY 10 5\nLIMIT b SELL 10 2\nBOOK"
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	want := "REST a\nTRADE b a 10 2\nFILLED b\nBID 10 3 1\n--\n"
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestRunMalformed(t *testing.T) {
	if err := run(strings.NewReader("1\nNOPE\n"), &bytes.Buffer{}); err == nil {
		t.Error("expected an error for malformed input")
	}
}
