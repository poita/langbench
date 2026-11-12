package script

import (
	"strings"
	"testing"
)

func run(t *testing.T, input string) string {
	t.Helper()
	var out strings.Builder
	if err := Run(strings.NewReader(input), &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out.String()
}

func TestSpecExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"single cursor",
			"2\nhello world\nsecond line\nmove end\ninsert !\nmove down\ninsert  (edited)\ngoto 0 5\ninsert ,\nprint\ndelete\ndelete\nprint\n",
			"hello, world!\nsecond line (edited)\ncursor 0 6\n--\nhell world!\nsecond line (edited)\ncursor 0 4\n--\n"},
		{"multiple cursors",
			"3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint\nmove end select\ninsert X\nprint\ngoto 0 1\nmove right select\nmove right select\ndelete\nprint\n",
			"- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n- X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n-\n- X\n- X\ncursor 0 1\n--\n"},
		{"undo and redo",
			"1\nabc\nmove end\ninsert d\\ne\nprint\ndelete\ndelete\nprint\nundo\nprint\nundo\nprint\nredo\nprint\ninsert Z\nredo\nprint\n",
			"abcd\ne\ncursor 1 1\n--\nabcd\ncursor 0 4\n--\nabcd\n\ncursor 1 0\n--\nabcd\ne\ncursor 1 1\n--\nabcd\n\ncursor 1 0\n--\nabcd\nZ\ncursor 1 1\n--\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.in); got != tc.want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestDocumentIsVerbatim(t *testing.T) {
	// Document lines keep their spaces and may look like commands.
	in := "3\n  padded  \nprint\ninsert x\nmove end\nprint\n"
	want := "  padded  \nprint\ninsert x\ncursor 0 10\n--\n"
	got := run(t, in)
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestEmptyDocumentAndNoPrint(t *testing.T) {
	if got := run(t, "0\nprint\n"); got != "\ncursor 0 0\n--\n" {
		t.Fatalf("got %q", got)
	}
	if got := run(t, "1\nabc\ninsert x\n"); got != "" {
		t.Fatalf("got %q, want no output", got)
	}
}

func TestNoTrailingNewline(t *testing.T) {
	if got := run(t, "1\nab\nmove end\nprint"); got != "ab\ncursor 0 2\n--\n" {
		t.Fatalf("got %q", got)
	}
}

func TestInsertKeepsSpaces(t *testing.T) {
	got := run(t, "1\n\ninsert   a  \nprint\n")
	if got != "  a  \ncursor 0 5\n--\n" {
		t.Fatalf("got %q", got)
	}
}

func TestGotoClamping(t *testing.T) {
	got := run(t, "2\nab\ncde\ngoto 1000000000 1000000000\nprint\ngoto 0 99\nprint\n")
	want := "ab\ncde\ncursor 1 3\n--\nab\ncde\ncursor 0 2\n--\n"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestErrors(t *testing.T) {
	for _, in := range []string{
		"",
		"x\n",
		"-1\n",
		"1\na\nfrobnicate\n",
		"1\na\nmove sideways\n",
		"1\na\nmove\n",
		"1\na\nmove left selekt\n",
		"1\na\ngoto 1\n",
		"1\na\ngoto a b\n",
		"1\na\ninsert\n",
		"1\na\ninsert bad\\q\n",
		"1\na\ndelete now\n",
		"1\na\nprint now\n",
	} {
		var out strings.Builder
		if err := Run(strings.NewReader(in), &out); err == nil {
			t.Errorf("Run(%q): expected an error", in)
		}
	}
}

func TestOutputBeforeErrorIsWritten(t *testing.T) {
	var out strings.Builder
	err := Run(strings.NewReader("1\na\nprint\nbogus\n"), &out)
	if err == nil || !strings.Contains(err.Error(), "line 4") {
		t.Fatalf("err = %v", err)
	}
	if out.String() != "a\ncursor 0 0\n--\n" {
		t.Fatalf("out = %q", out.String())
	}
}

func TestDecodeInsert(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"plain", "plain"},
		{`a\nb`, "a\nb"},
		{`\\`, `\`},
		{`\\n`, `\n`},
		{`\\\n`, "\\\n"},
		{` x `, ` x `},
	} {
		got, err := DecodeInsert(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("DecodeInsert(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
	}
	for _, bad := range []string{`\`, `a\`, `\x`} {
		if _, err := DecodeInsert(bad); err == nil {
			t.Errorf("DecodeInsert(%q): expected an error", bad)
		}
	}
}
