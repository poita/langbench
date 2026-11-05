package script

import (
	"bytes"
	"testing"
)

func runScript(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run([]byte(in), &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out.String()
}

func TestSpecExample1(t *testing.T) {
	in := "2\nhello world\nsecond line\nmove end\ninsert !\nmove down\ninsert  (edited)\n" +
		"goto 0 5\ninsert ,\nprint\ndelete\ndelete\nprint\n"
	want := "hello, world!\nsecond line (edited)\ncursor 0 6\n--\n" +
		"hell world!\nsecond line (edited)\ncursor 0 4\n--\n"
	if got := runScript(t, in); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestSpecExample2TrailingSpace(t *testing.T) {
	in := "3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint"
	want := "- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n"
	if got := runScript(t, in); got != want { // no final newline on input
		t.Errorf("got %q want %q", got, want)
	}
}

func TestEscapesAndVerbatimDocument(t *testing.T) {
	// A document line that looks like a command, with spaces at both ends.
	in := "2\n print \ninsert x\ninsert a\\\\b\\nc\nprint\n"
	want := "a\\b\nc print \ninsert x\ncursor 1 1\n--\n"
	if got := runScript(t, in); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestZeroLinesAndNoPrint(t *testing.T) {
	if got := runScript(t, "0\ninsert hi\n"); got != "" {
		t.Errorf("output without print: %q", got)
	}
	if got := runScript(t, "0\nprint\n"); got != "\ncursor 0 0\n--\n" {
		t.Errorf("got %q", got)
	}
	if got := runScript(t, ""); got != "" {
		t.Errorf("empty input: %q", got)
	}
}

func TestHugeNumbersClamp(t *testing.T) {
	got := runScript(t, "1\nabc\ngoto 1000000000 1000000000\nprint\n")
	if got != "abc\ncursor 0 3\n--\n" {
		t.Errorf("got %q", got)
	}
}

func TestErrors(t *testing.T) {
	for _, in := range []string{
		"x\n", "0\nfrobnicate\n", "0\ninsert\n", "0\nmove sideways\n",
		"0\nmove left sel\n", "0\ngoto 1\n", "0\ngoto a b\n",
	} {
		var out bytes.Buffer
		if err := Run([]byte(in), &out); err == nil {
			t.Errorf("%q: expected an error", in)
		}
	}
}

func TestDecodeEscapes(t *testing.T) {
	for in, want := range map[string]string{
		`a\nb`: "a\nb", `\\n`: `\n`, `\\`: `\`, `x\`: `x\`, `plain`: "plain",
	} {
		if got := string(decodeEscapes(nil, []byte(in))); got != want {
			t.Errorf("decode(%q) = %q want %q", in, got, want)
		}
	}
}
