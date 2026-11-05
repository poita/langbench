package batch

import (
	"strings"
	"testing"
)

const schemaText = "message Inner { sint32 v = 1; }\nmessage Outer {\n  int32 a = 1;\n  string b = 2;\n  repeated int32 c = 3;\n  Inner d = 4;\n}\n"

func run(t *testing.T, requests string) string {
	t.Helper()
	out, err := Run([]byte(schemaText + "--\n" + requests))
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestSpecExample(t *testing.T) {
	got := run(t, strings.Join([]string{
		`encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}`,
		`decode Outer 08011201781a02010222020809`,
		`encode Outer {d: {}, c: [], a: 0}`,
		`decode Outer 3800`,
		`decode Outer 08ff`,
	}, "\n")+"\n")
	want := "08011201781a02010222020809\n{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n2200\n{}\nerror\n"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestNoTrailingNewline(t *testing.T) {
	if got := run(t, "decode Outer 0801"); got != "{a: 1}\n" {
		t.Errorf("got %q", got)
	}
}

func TestMalformedRequests(t *testing.T) {
	reqs := []string{
		"decode Outer ",         // trailing space
		"decode Outer 080",      // odd digits
		"decode Outer 08G1",     // non-hex
		"decode Outer 0801 ",    // trailing space after hex
		"decode Outer 08 01",    // extra text
		"decode Outer 0A",       // uppercase hex... also truncated
		"decode Nope 08",        // unknown message
		"decode",                // no name
		"frobnicate Outer 08",   // unknown command
		"encode Outer",          // no text
		"encode Outer ",         // empty text
		"encode Outer    ",      // spaces only
		"encode Outer {} extra", // trailing text
		"",                      // blank line
	}
	got := run(t, strings.Join(reqs, "\n")+"\n")
	want := strings.Repeat("error\n", len(reqs))
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestEmptyPayloads(t *testing.T) {
	if got := run(t, "decode Outer\nencode Outer {}\nencode Outer   {  }  \n"); got != "{}\n\n\n" {
		t.Errorf("got %q", got)
	}
}

func TestFailedRequestLeavesNoPartialOutput(t *testing.T) {
	got := run(t, "decode Outer 0801120178 \ndecode Outer 08011202\ndecode Outer 0802\n")
	if got != "error\nerror\n{a: 2}\n" {
		t.Errorf("got %q", got)
	}
}

func TestSplit(t *testing.T) {
	cases := []struct{ in, schema, reqs string }{
		{"s\n--\nr1\nr2", "s\n", "r1\nr2"},
		{"--\nr", "", "r"},
		{"s\n--", "s\n", ""},
		{"s\n---\nr\n--\nx", "s\n---\nr\n", "x"},
		{"no separator", "no separator", ""},
	}
	for _, c := range cases {
		s, r := Split([]byte(c.in))
		if string(s) != c.schema || string(r) != c.reqs {
			t.Errorf("Split(%q) = %q, %q; want %q, %q", c.in, s, r, c.schema, c.reqs)
		}
	}
}

func TestBadSchema(t *testing.T) {
	if _, err := Run([]byte("message A { Missing x = 1; }\n--\ndecode A\n")); err == nil {
		t.Error("expected schema error")
	}
}
