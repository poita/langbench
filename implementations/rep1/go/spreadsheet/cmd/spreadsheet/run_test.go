package main

import "testing"

func TestRunExamples(t *testing.T) {
	in := "set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\nset A1 5\nget A3\ndump"
	want := "42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n"
	if got := string(Run(in)); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRunEmptyAndNoTrailingNewline(t *testing.T) {
	if got := Run(""); len(got) != 0 {
		t.Errorf("got %q", got)
	}
	if got := string(Run("get B7\nset A1 \"a b\"\nget A1")); got != "\na b\n" {
		t.Errorf("got %q", got)
	}
	if got := Run("set A1 1\nclear A1\ndump\n"); len(got) != 0 {
		t.Errorf("got %q", got)
	}
}
