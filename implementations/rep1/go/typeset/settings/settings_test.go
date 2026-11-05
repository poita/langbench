package settings

import (
	"testing"

	"typeset/diag"
)

func parseErr(t *testing.T, src string) *diag.Error {
	t.Helper()
	_, err := Parse([]byte(src))
	if err == nil {
		t.Fatalf("expected an error for %q", src)
	}
	return err
}

func TestDefaults(t *testing.T) {
	s, err := Parse(nil)
	if err != nil {
		t.Fatal(err)
	}
	if s.BodyWidth() != 468000 || s.BodyHeight() != 648000 || s.FooterBaseline != 756000 || s.FootnoteMaxHeight != 324000 {
		t.Errorf("derived defaults wrong: %d %d %d %d", s.BodyWidth(), s.BodyHeight(), s.FooterBaseline, s.FootnoteMaxHeight)
	}
}

func TestAssignments(t *testing.T) {
	src := "# comment\n\tpage-width = 200pt\npage-height=120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\nalign = center\nhyphenate = off\nheader-left = a\\{{page}b\n"
	s, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if s.BodyWidth() != 160000 || s.BodyHeight() != 80000 || s.Align != Center || s.Hyphenate {
		t.Errorf("settings not applied: %+v", s.BodyWidth())
	}
	if s.FooterBaseline != 84000 || s.FootnoteMaxHeight != 40000 {
		t.Errorf("footer-baseline/footnote-max-height should follow the page: %d %d", s.FooterBaseline, s.FootnoteMaxHeight)
	}
	got := s.Slots[0][0]
	if len(got) != 3 || got[0].Lit != "a{" || got[1].Placeholder != "page" || got[2].Lit != "b" {
		t.Errorf("text parse = %+v", got)
	}
	if len(s.Slots[1][0]) != 3 {
		t.Error("even slot should default to the odd slot")
	}
}

func TestErrors(t *testing.T) {
	cases := []struct {
		src       string
		line, col int
		code      string
	}{
		{"page-width = 200pt\nmargin-left = 20px\n", 2, 15, "bad-length"},
		{"margin-top =\n", 1, 13, "bad-length"},
		{"no equals\n", 1, 1, "bad-syntax"},
		{"  frobnicate = 1\n", 1, 3, "unknown-setting"},
		{"widows = 2\n  widows = 3\n", 2, 3, "duplicate-setting"},
		{"widows = 0\n", 1, 10, "bad-value"},
		{"widows = x\n", 1, 10, "bad-integer"},
		{"hyphenate = yes\n", 1, 13, "bad-boolean"},
		{"align = middle\n", 1, 9, "bad-enum"},
		{"body-font = comic\n", 1, 13, "unknown-font"},
		{"hyphen-patterns = french\n", 1, 19, "unknown-patterns"},
		{"toc-leader = . .\n", 1, 14, "bad-value"},
		{"toc-title = {title}\n", 1, 13, "bad-value"},
		{"footer-right = {page\n", 1, 16, "unknown-placeholder"},
		{"header-left = \\q\n", 1, 15, "bad-escape"},
		{"header-left = \\{page}\n", 1, 21, "stray-brace"},
		{"margin-bottom = 50pt\npage-height = 120pt\nmargin-top = 40pt\nalign = left\n", 3, 14, "bad-value"},
	}
	for _, c := range cases {
		e := parseErr(t, c.src)
		if e.Line != c.line || e.Col != c.col || e.Code != c.code || e.File != "settings.cfg" {
			t.Errorf("%q: got %v want %d:%d %s", c.src, e, c.line, c.col, c.code)
		}
	}
}
