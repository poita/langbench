package batch

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
	"testing/iotest"
)

func run(t *testing.T, input string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(strings.NewReader(input), &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out.String()
}

func TestSpecExample(t *testing.T) {
	in := "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
	want := "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestVerbatimLines(t *testing.T) {
	// Patterns and subjects may be empty or all spaces, and are never trimmed.
	in := "3\n \n2\n\n  \n\n1\nab\n2\n1\n 2\n"
	want := "no\nmatch 0 1\nmatch 0 0\nmatch 1 2\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPatternLooksLikeInteger(t *testing.T) {
	in := "3\n2\n1\n2\n3\n0\n\n1\n\n"
	// pattern "2" on subject "2" -> match; pattern "3" has no subjects;
	// pattern "" on subject "" -> empty match.
	want := "match 0 1\nmatch 0 0\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSpacesArePartOfLines(t *testing.T) {
	in := "2\n a \n3\n a \na\n  a  \n^ *$\n2\n   \n\n"
	want := "match 0 3\nno\nmatch 1 4\nmatch 0 3\nmatch 0 0\n"
	if got := run(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNoOutputWhenNoSubjects(t *testing.T) {
	if got := run(t, "2\na\n0\n(b)\n0\n"); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestMissingFinalNewline(t *testing.T) {
	if got := run(t, "1\na\n1\nxa"); got != "match 1 2\n" {
		t.Errorf("got %q", got)
	}
}

func TestLongLine(t *testing.T) {
	subject := strings.Repeat("a", 3<<20) // longer than the read buffer
	got := run(t, "1\n(a*)$\n1\n"+subject+"\n")
	want := "match 0 3145728|0,3145728\n"
	if got != want {
		t.Errorf("got %q", got)
	}
}

func TestSlowReader(t *testing.T) {
	r := iotest.OneByteReader(strings.NewReader("1\n(b)\n2\nab\nc\n"))
	var out bytes.Buffer
	if err := Run(r, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "match 1 2|1,2\nno\n" {
		t.Errorf("got %q", out.String())
	}
}

func TestErrors(t *testing.T) {
	for name, in := range map[string]string{
		"empty input":       "",
		"bad count":         "x\n",
		"negative count":    "-1\n",
		"truncated":         "2\na\n1\nb\n",
		"missing subjects":  "1\na\n2\nb\n",
		"invalid pattern":   "1\n(\n0\n",
		"bad subject count": "1\na\nz\n",
	} {
		if err := Run(strings.NewReader(in), io.Discard); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

func TestWriteError(t *testing.T) {
	if err := Run(strings.NewReader("1\na\n1\na\n"), failWriter{}); err == nil {
		t.Error("expected write error")
	}
}
