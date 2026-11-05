package batch

import (
	"bytes"
	"testing"
)

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run([]byte(in), &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out.String()
}

func TestSpecExamples(t *testing.T) {
	in := "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
	want := "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPositionalLines(t *testing.T) {
	// Patterns and subjects may be empty, all spaces, or look like integers.
	in := "3\n" +
		"\n2\n\n  \n" + // empty pattern; subjects "" and "  "
		" 1 \n0\n" + // pattern " 1 " with no subjects
		"^ +$\n2\n   \n2\n" // subjects "   " and "2"
	want := "match 0 0\nmatch 0 0\nmatch 0 3\nno\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestZeroSubjects(t *testing.T) {
	if got := run(t, "2\na\n0\nb\n0\n"); got != "" {
		t.Errorf("got %q, want empty output", got)
	}
}

func TestLastSubjectWithoutNewline(t *testing.T) {
	if got := run(t, "1\nb\n1\nabc"); got != "match 1 2\n" {
		t.Errorf("got %q", got)
	}
}

func TestErrors(t *testing.T) {
	for _, in := range []string{"", "x\n", "1\n(\n1\na\n", "2\na\n1\na\n", "1\na\n3\na\n"} {
		if err := Run([]byte(in), &bytes.Buffer{}); err == nil {
			t.Errorf("Run(%q) succeeded, want error", in)
		}
	}
}

func TestAppendInt(t *testing.T) {
	for _, v := range []int{0, 7, 10, 12345, 10000} {
		want := map[int]string{0: "0", 7: "7", 10: "10", 12345: "12345", 10000: "10000"}[v]
		if got := string(appendInt(nil, v)); got != want {
			t.Errorf("appendInt(%d) = %q", v, got)
		}
	}
}
