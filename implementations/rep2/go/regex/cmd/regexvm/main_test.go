package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	in := "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
	want := "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestRunPositional(t *testing.T) {
	// Pattern lines that look like integers, empty subjects, M = 0, spaces.
	in := "3\n5\n2\n5\n 5\nx\n0\n a \n1\n a \n"
	want := "match 0 1\nmatch 1 2\nmatch 0 3\n"
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestRunErrors(t *testing.T) {
	for _, in := range []string{"", "x\n", "1\n(\n0\n", "2\na\n1\nb\n", "1\na\n3\nb\n"} {
		if err := run(strings.NewReader(in), &bytes.Buffer{}); err == nil {
			t.Errorf("input %q: expected error", in)
		}
	}
}

func TestAppendInt(t *testing.T) {
	for v, want := range map[int]string{0: "0", 7: "7", 10: "10", 123456: "123456"} {
		if got := string(appendInt(nil, v)); got != want {
			t.Errorf("appendInt(%d) = %q", v, got)
		}
	}
}
