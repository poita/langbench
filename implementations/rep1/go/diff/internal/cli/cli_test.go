package cli

import (
	"bytes"
	"strings"
	"testing"
)

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestPatchExample(t *testing.T) {
	in := "patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n"
	if got, want := run(t, in), "6\na\nB\nc\nc2\ne\nf\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestPatchTrickyLines(t *testing.T) {
	// Content lines that look like counts or tags.
	in := "patch\n3\n5\n-\n+1\n5\n 5\n--\n-+1\n+-x\n+ \n"
	if got, want := run(t, in), "3\n5\n-x\n \n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if got := run(t, "patch\n0\n0\n"); got != "0\n" {
		t.Fatalf("got %q", got)
	}
}

func TestDiffExample(t *testing.T) {
	in := "diff\n3\na\nb\nc\n3\na\nc\nd\n"
	if got, want := run(t, in), "4\n a\n-b\n c\n+d\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if got := run(t, "diff\n0\n0\n"); got != "0\n" {
		t.Fatalf("got %q", got)
	}
}

func TestDiffKeepsEmptyAndTrailingSpace(t *testing.T) {
	in := "diff\n2\n\nx \n2\n\nx\n"
	if got, want := run(t, in), "3\n \n-x \n+x\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestLenientInput(t *testing.T) {
	in := "diff\n1 \na\n1\t\nb" // trailing blanks on counts, no final newline
	if got, want := run(t, in), "2\n-a\n+b\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestErrors(t *testing.T) {
	for _, in := range []string{
		"", "bogus\n", "diff\nx\n", "diff\n3\na\n", "diff\n-1\n",
		"patch\n1\na\n1\n-b\n", "patch\n0\n1\n?x\n", "diff\n99999999999\n",
	} {
		if err := Run(strings.NewReader(in), &bytes.Buffer{}); err == nil {
			t.Errorf("input %q: expected an error", in)
		}
	}
}
