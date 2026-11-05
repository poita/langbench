package main

import (
	"bytes"
	"testing"
)

func runString(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run([]byte(in), &out); err != nil {
		t.Fatalf("run: %v", err)
	}
	return out.String()
}

func TestSpecExample1(t *testing.T) {
	in := "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
	want := "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
	if got := runString(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPositionalFormat(t *testing.T) {
	// Patterns and subjects that look like integers, are blank, or have
	// leading and trailing spaces; an M = 0 pattern produces no output.
	in := "4\n 1 \n3\n 1 \n1\n   \n12\n0\n\n2\n\n  \n^$\n1\n\n"
	want := "match 0 3\nno\nno\n" + // " 1 " on " 1 ", "1", "   "
		"match 0 0\nmatch 0 0\n" + // "" on "", "  "
		"match 0 0\n" // ^$ on ""
	if got := runString(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestEmptyOutput(t *testing.T) {
	if got := runString(t, "1\na\n0\n"); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestErrors(t *testing.T) {
	var out bytes.Buffer
	for _, in := range []string{"", "x\n", "1\n(\n0\n", "1\na\n2\nb\n", "2\na\n0\n"} {
		if err := run([]byte(in), &out); err == nil {
			t.Errorf("run(%q) succeeded, want error", in)
		}
	}
}

func TestAppendUint(t *testing.T) {
	for n, want := range map[int]string{0: "0", 7: "7", 10: "10", 12345: "12345", 1 << 40: "1099511627776"} {
		if got := string(appendUint(nil, n)); got != want {
			t.Errorf("appendUint(%d) = %q, want %q", n, got, want)
		}
	}
}
