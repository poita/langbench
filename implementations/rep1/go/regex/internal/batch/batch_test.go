package batch

import (
	"strings"
	"testing"
)

func runBatch(t *testing.T, in string) string {
	t.Helper()
	var out strings.Builder
	if err := Run(strings.NewReader(in), &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out.String()
}

func TestRunSpecExample(t *testing.T) {
	in := "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
	want := "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
	if got := runBatch(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestRunVerbatimLines(t *testing.T) {
	// Empty and space-only subjects, a pattern with spaces, a zero-subject
	// pattern, and a subject that looks like an integer.
	in := "3\n a \n3\n\n a \n12\nx\n0\n\n2\n\n7\n"
	want := "no\nmatch 0 3\nno\nmatch 0 0\nmatch 0 0\n"
	if got := runBatch(t, in); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestRunNoOutputForZeroSubjects(t *testing.T) {
	if got := runBatch(t, "1\nabc\n0\n"); got != "" {
		t.Errorf("got %q", got)
	}
}

func TestRunLongLine(t *testing.T) {
	long := strings.Repeat("a", 3<<20)
	if got := runBatch(t, "1\na$\n1\n"+long+"\n"); got != "match 3145727 3145728\n" {
		t.Errorf("got %q", got)
	}
}

func TestRunErrors(t *testing.T) {
	for _, in := range []string{"", "x\n", "1\n(\n0\n", "1\na\n2\nb\n", "1\na\n-1\n"} {
		var out strings.Builder
		if err := Run(strings.NewReader(in), &out); err == nil {
			t.Errorf("Run(%q) succeeded", in)
		}
	}
}

// The pattern line must survive the buffer refill triggered by reading the
// following count line.
func TestRunPatternAcrossBufferBoundary(t *testing.T) {
	var in strings.Builder
	in.WriteString("2000\n")
	for i := 0; i < 2000; i++ {
		in.WriteString("(x" + strings.Repeat("y", 400) + ")\n1\nx" + strings.Repeat("y", 400) + "\n")
	}
	got := runBatch(t, in.String())
	if strings.Count(got, "match 0 401|0,401\n") != 2000 {
		t.Errorf("unexpected output (%d bytes)", len(got))
	}
}
