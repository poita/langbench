package header

import (
	"testing"
)

func TestParse(t *testing.T) {
	msg := "Subject: hello\n world\nX-A:1\nx-a:2\n\nbody\n"
	fields, start := Parse([]byte(msg))
	if len(fields) != 3 {
		t.Fatalf("got %d fields: %+v", len(fields), fields)
	}
	if fields[0].Name != "subject" || fields[0].Raw != " hello world" {
		t.Errorf("field 0 = %+v", fields[0])
	}
	if msg[start:] != "body\n" {
		t.Errorf("body = %q", msg[start:])
	}
	if f, _ := Find(fields, "x-a"); f.Raw != "1" {
		t.Errorf("Find must return the first field, got %+v", f)
	}
}

func TestParseEnds(t *testing.T) {
	cases := []struct {
		in         string
		nfields    int
		bodyOffset int
	}{
		{"", 0, 0},
		{"A: b", 1, 4},
		{"A: b\nno colon here\nrest", 1, 5},
		{"A: b\nSubject :x\n", 1, 5},
		{"A: b\n: novalue\n", 1, 5},
		{"A: b\nFrom nobody Mon Sep  1\n", 1, 5},
		{" lead: x\nA: b\n", 0, 0},
		{"\nA: b\n", 0, 1},
		{"A: b\n\n", 1, 6},
	}
	for _, c := range cases {
		fields, off := Parse([]byte(c.in))
		if len(fields) != c.nfields || off != c.bodyOffset {
			t.Errorf("Parse(%q) = %d fields, offset %d; want %d, %d", c.in, len(fields), off, c.nfields, c.bodyOffset)
		}
	}
}

func TestParseDoesNotAliasFolding(t *testing.T) {
	buf := []byte("A: one\n two\nB: x\n\n")
	fields, _ := Parse(buf)
	if string(buf) != "A: one\n two\nB: x\n\n" {
		t.Errorf("buffer modified: %q", buf)
	}
	if fields[1].Raw != " x" {
		t.Errorf("B = %q", fields[1].Raw)
	}
}

func TestCollapse(t *testing.T) {
	if got := Collapse("  a \t b   c "); got != "a b c" {
		t.Errorf("Collapse = %q", got)
	}
}

func TestDisplayValue(t *testing.T) {
	f := Field{Name: "subject", Raw: " =?utf-8?Q?caf=C3=A9?= "}
	if got := f.DisplayValue(); got != "café" {
		t.Errorf("subject = %q", got)
	}
	f = Field{Name: "content-type", Raw: "  text/plain;   x=1 "}
	if got := f.DisplayValue(); got != "text/plain; x=1" {
		t.Errorf("content-type = %q", got)
	}
	f = Field{Name: "date", Raw: " =?utf-8?Q?x?= "}
	if got := f.DisplayValue(); got != "=?utf-8?Q?x?=" {
		t.Errorf("date must not be decoded, got %q", got)
	}
}
