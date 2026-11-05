package main

import "testing"

func run(t *testing.T, in string) string {
	t.Helper()
	out, err := Run([]byte(in))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return string(out)
}

func TestRunDiffExample(t *testing.T) {
	in := "diff\n7\na\nb\nc\na\nb\nb\na\n6\nc\nb\na\nb\na\nc\n"
	out := run(t, in)
	if out[:2] != "9\n" {
		t.Fatalf("output %q", out)
	}
}

func TestRunDiffEmpty(t *testing.T) {
	if got := run(t, "diff\n0\n0\n"); got != "0\n" {
		t.Fatalf("%q", got)
	}
}

func TestRunPatchExample(t *testing.T) {
	in := "patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n"
	if got, want := run(t, in), "6\na\nB\nc\nc2\ne\nf\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestRunPatchEmptyResult(t *testing.T) {
	if got := run(t, "patch\n1\nx\n1\n-x\n"); got != "0\n" {
		t.Fatalf("%q", got)
	}
}

func TestRunContentLooksLikeCounts(t *testing.T) {
	// Lines "5", "-", "+", " " are content, not counts or tags.
	in := "diff\n3\n5\n-\n \n3\n+\n5\n \n"
	out := run(t, in)
	if out[:2] != "4\n" { // keep "5"? A=[5,-," "], B=[+,5," "] -> LCS 2
		t.Fatalf("output %q", out)
	}
	in = "patch\n2\n5\n \n3\n 5\n-\x20\n+-x\n"
	if got, want := run(t, in), "2\n5\n-x\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestRunLeniencies(t *testing.T) {
	// CRLF, trailing blanks on count lines, no final newline, extra empty lines.
	in := "diff\r\n1 \t\r\nx\r\n1  \r\nx"
	if got := run(t, in); got != "1\n x\n" {
		t.Fatalf("%q", got)
	}
	in = "diff\n1\nx\n1\nx\n\n\n"
	if got := run(t, in); got != "1\n x\n" {
		t.Fatalf("%q", got)
	}
}

func TestRunErrors(t *testing.T) {
	for _, in := range []string{"", "bogus\n0\n0\n", "diff\nx\n0\n", "diff\n2\na\n0\n", "diff\n0\n", "patch\n0\n1\nzzz\n", "patch\n1\na\n1\n-b\n"} {
		if _, err := Run([]byte(in)); err == nil {
			t.Errorf("Run(%q): want error", in)
		}
	}
}
