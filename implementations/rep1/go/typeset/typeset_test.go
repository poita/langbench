package typeset_test

import (
	"os"
	"strings"
	"testing"

	"typeset"
)

// The real font and pattern data ships with the problem, not with the
// library; the end-to-end tests are skipped when it is not available.
func resources(t *testing.T) *typeset.Resources {
	t.Helper()
	dir := os.Getenv("TYPESET_DATA")
	if dir == "" {
		dir = "../problems/typeset/data"
	}
	if _, err := os.Stat(dir); err != nil {
		t.Skipf("no data directory at %s (set TYPESET_DATA)", dir)
	}
	r, err := typeset.LoadResources(dir)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

const small = `page-width   = 200pt
page-height  = 120pt
margin-top   = 20pt
margin-bottom = 20pt
margin-left  = 20pt
margin-right = 20pt
`

func TestExampleOneLine(t *testing.T) {
	res := typeset.Typeset(typeset.Input{Document: []byte("The quick brown fox.\n"), HasDocument: true,
		Settings: []byte(small), HasSettings: true}, resources(t))
	if res.Err != nil {
		t.Fatal(res.Err)
	}
	want := `layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 15630 "The"
  text body serif 10000 56170 27310 22240 "quick"
  text body serif 10000 80950 27310 25140 "brown"
  text body serif 10000 108630 27310 15810 "fox."
`
	if res.Layout != want {
		t.Errorf("layout mismatch:\n%s", res.Layout)
	}
	if !strings.Contains(res.Report, "lines 1\n") || !strings.HasSuffix(res.Report, "total-demerits 100\n") {
		t.Errorf("report mismatch:\n%s", res.Report)
	}
}

func TestExampleTwoLines(t *testing.T) {
	res := typeset.Typeset(typeset.Input{Document: []byte("The quick brown fox jumps over the lazy dog.\n"), HasDocument: true,
		Settings: []byte(small), HasSettings: true}, resources(t))
	if res.Err != nil {
		t.Fatal(res.Err)
	}
	if !strings.Contains(res.Layout, `text body serif 10000 55521 27310 22240 "quick"`) ||
		!strings.HasSuffix(res.Report, "total-demerits 3016\n") {
		t.Errorf("unexpected output:\n%s\n%s", res.Layout, res.Report)
	}
}

func TestEmptyDocument(t *testing.T) {
	res := typeset.Typeset(typeset.Input{HasDocument: true}, resources(t))
	if res.Err != nil || res.Layout != "layout 1\npages 0\n" {
		t.Errorf("empty document: %v %q", res.Err, res.Layout)
	}
}

func TestErrors(t *testing.T) {
	r := resources(t)
	cases := []struct {
		in   typeset.Input
		want string
	}{
		{typeset.Input{}, "-:0:0: missing-document\n"},
		{typeset.Input{HasDocument: true, HasSettings: true, Settings: []byte("page-width = 200pt\nmargin-left = 20px\n")},
			"settings.cfg:2:15: bad-length\n"},
		{typeset.Input{HasDocument: true, Document: []byte("@h1 Title\n{z|oops}\n")}, "document.cdx:2:1: unknown-inline\n"},
	}
	for _, c := range cases {
		res := typeset.Typeset(c.in, r)
		if res.Err == nil || res.ErrorText() != c.want {
			t.Errorf("got %v want %q", res.Err, c.want)
		}
	}
}

func TestTableOfContents(t *testing.T) {
	doc := "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n"
	res := typeset.Typeset(typeset.Input{Document: []byte(doc), HasDocument: true, Settings: []byte(small), HasSettings: true}, resources(t))
	if res.Err != nil {
		t.Fatal(res.Err)
	}
	if !strings.Contains(res.Layout, "page 1 i ") || !strings.Contains(res.Layout, "page 3 2 ") ||
		!strings.Contains(res.Report, "front-pages 1\n") || !strings.HasSuffix(res.Report, "total-demerits 700\n") {
		t.Errorf("unexpected output:\n%s\n%s", res.Layout, res.Report)
	}
}
