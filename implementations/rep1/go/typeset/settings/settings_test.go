package settings

import "testing"

func errOf(src string) string {
	_, e := Parse([]byte(src))
	if e == nil {
		return ""
	}
	return e.Error()
}

func TestDefaults(t *testing.T) {
	s, e := Parse(nil)
	if e != nil {
		t.Fatal(e)
	}
	if s.BodyWidth() != 468000 || s.BodyHeight() != 648000 {
		t.Errorf("body %d x %d", s.BodyWidth(), s.BodyHeight())
	}
	if s.FooterBaseline != 756000 || s.FootnoteMaxHeight != 324000 {
		t.Errorf("derived defaults: %d %d", s.FooterBaseline, s.FootnoteMaxHeight)
	}
}

func TestDerivedDefaultsFollowGeometry(t *testing.T) {
	s, e := Parse([]byte("page-height = 500pt\nmargin-top = 10pt\n"))
	if e != nil {
		t.Fatal(e)
	}
	if s.FooterBaseline != 464000 {
		t.Errorf("footer-baseline = %d", s.FooterBaseline)
	}
	if want := s.BodyHeight() / 2; s.FootnoteMaxHeight != want {
		t.Errorf("footnote-max-height = %d, want %d", s.FootnoteMaxHeight, want)
	}
}

func TestEvenSlotsFallBack(t *testing.T) {
	s, e := Parse([]byte("header-left = a\nheader-right-even = b\n"))
	if e != nil {
		t.Fatal(e)
	}
	if s.Slots[1][HeaderLeft].Literal() != "a" || s.Slots[1][HeaderRight].Literal() != "b" {
		t.Errorf("even slots: %+v", s.Slots[1])
	}
	if len(s.Slots[0][HeaderRight]) != 0 {
		t.Error("odd right slot should be empty")
	}
}

func TestErrors(t *testing.T) {
	cases := []struct{ src, want string }{
		{"page-width = 200pt\nmargin-left = 20px\n", "settings.cfg:2:15: bad-length"},
		{"nonsense\n", "settings.cfg:1:1: bad-syntax"},
		{"  = 3\n", "settings.cfg:1:3: bad-syntax"},
		{"foo = 3\n", "settings.cfg:1:1: unknown-setting"},
		{"widows = 2\n\twidows = 3\n", "settings.cfg:2:2: duplicate-setting"},
		{"widows = x\n", "settings.cfg:1:10: bad-integer"},
		{"hyphenate = yes\n", "settings.cfg:1:13: bad-boolean"},
		{"align = middle\n", "settings.cfg:1:9: bad-enum"},
		{"body-font = comic\n", "settings.cfg:1:13: unknown-font"},
		{"hyphen-patterns = x\n", "settings.cfg:1:19: unknown-patterns"},
		{"widows = 0\n", "settings.cfg:1:10: bad-value"},
		{"body-size =\n", "settings.cfg:1:12: bad-length"},
		{"toc-leader = a b\n", "settings.cfg:1:14: bad-value"},
		{"toc-title = {page}\n", "settings.cfg:1:13: bad-value"},
		{"header-left = {pa\\ge}\n", "settings.cfg:1:15: unknown-placeholder"},
		{"header-left = \\{page}\n", "settings.cfg:1:21: stray-brace"},
		{"header-left = }\\q\n", "settings.cfg:1:15: stray-brace"},
		{"header-left = a\\q\n", "settings.cfg:1:16: bad-escape"},
		{"header-left = {page\n", "settings.cfg:1:15: unknown-placeholder"},
		{"page-width = 20pt\n", "settings.cfg:1:14: bad-value"},
		{"margin-left = 300pt\nmargin-right = 300pt\n", "settings.cfg:2:16: bad-value"},
	}
	for _, c := range cases {
		if got := errOf(c.src); got != c.want {
			t.Errorf("%q: got %q, want %q", c.src, got, c.want)
		}
	}
}

func TestTextPlaceholders(t *testing.T) {
	s, e := Parse([]byte("header-center = Page {page} of {pages} \\{x\\}\n"))
	if e != nil {
		t.Fatal(e)
	}
	tpl := s.Slots[0][HeaderCenter]
	if len(tpl) != 5 || tpl[1].Placeholder != "page" || tpl[4].Literal != " {x}" {
		t.Errorf("template = %+v", tpl)
	}
}
