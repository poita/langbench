package codexa

import "testing"

func parseErr(src string) string {
	_, e := Parse([]byte(src))
	if e == nil {
		return ""
	}
	return e.Error()
}

func TestErrors(t *testing.T) {
	cases := []struct{ src, want string }{
		{"@h1 Title\n{z|oops}\n", "document.cdx:2:1: unknown-inline"},
		{"@bogus\n", "document.cdx:1:1: unknown-block"},
		{"@h1x A\n", "document.cdx:1:1: unknown-block"},
		{"@hrule\n", "document.cdx:1:1: block-not-allowed"},
		{"@toc\n@toc\n", "document.cdx:2:1: duplicate-toc"},
		{"text\n@toc\n", "document.cdx:2:1: block-not-allowed"},
		{"@end\n", "document.cdx:1:1: unexpected-end"},
		{"@end foo=1\n", "document.cdx:1:6: bad-attribute"},
		{"@q\ntext\n", "document.cdx:3:1: missing-end"},
		{"@pre\nabc\n", "document.cdx:3:1: missing-end"},
		{"@table cols=0 foo=1\n", "document.cdx:1:15: bad-attribute"},
		{"@table align=xyz\n", "document.cdx:1:1: missing-attribute"},
		{"@table cols=2 align=l\n@end\n", "document.cdx:1:21: bad-attribute-value"},
		{"@fig height=10pt width=\"10pt\"x\n", "document.cdx:1:24: bad-attribute-value"},
		{"@fig height=\n", "document.cdx:1:13: bad-attribute-value"},
		{"@table cols=1\n@vspace height=abc\n@end\n", "document.cdx:2:1: block-not-allowed"},
		{"@table cols=2\na\n@end\n", "document.cdx:2:1: cell-count"},
		{"@table cols=3\n{b|x} | y\n@end\n", "document.cdx:2:1: unknown-inline"},
		{"@ul\nstray\n@li a\n@end\n", "document.cdx:2:1: text-not-allowed"},
		{"@doc\ntitle = a\ntitle = b\n@end\n", "document.cdx:3:1: duplicate-meta"},
		{"@doc\nfoo = a\n@end\n", "document.cdx:2:1: unknown-meta"},
		{"@doc\nnot a key\n@end\n", "document.cdx:2:1: bad-syntax"},
		{"a {b|c\n", "document.cdx:1:3: unclosed-inline"},
		{"a }\n", "document.cdx:1:3: stray-brace"},
		{"abc\\\n", "document.cdx:1:4: bad-escape"},
		{"abc\\\ndef\n", ""}, // the backslash escapes the joining space
		{"a {n|b {n|c}}\n", "document.cdx:1:8: nested-footnote"},
		{"@h2 a {n|b}\n", "document.cdx:1:7: footnote-not-allowed"},
		{"@fig height=1pt\n{z|bad}\n@rule\n@end\n", "document.cdx:3:1: block-not-allowed"},
	}
	for _, c := range cases {
		if got := parseErr(c.src); got != c.want {
			t.Errorf("%q: got %q, want %q", c.src, got, c.want)
		}
	}
}

func TestInlineStyles(t *testing.T) {
	doc, e := Parse([]byte("a {b|x {+|y}} z\\ w~v\\-q\n"))
	if e != nil {
		t.Fatal(e)
	}
	in := doc.Blocks[0].(*Paragraph).Text
	var kinds []UnitKind
	for _, u := range in {
		kinds = append(kinds, u.Kind)
	}
	// a _ x _ y _ z rigid w rigid v disc q
	want := []UnitKind{Char, Space, Char, Space, Char, Space, Char, Rigid, Char, Rigid, Char, Disc, Char}
	if len(kinds) != len(want) {
		t.Fatalf("kinds %v", kinds)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Errorf("unit %d kind %d want %d", i, kinds[i], want[i])
		}
	}
	if y := in[4]; !y.Style.Bold || y.Style.Size != "+" {
		t.Errorf("y style %+v", y.Style)
	}
	if in[6].Style.Bold {
		t.Error("style leaked out of {b|...}")
	}
}

func TestSpaceCollapsing(t *testing.T) {
	doc, _ := Parse([]byte("  a   b  \n   c\n"))
	got := PlainText(doc.Blocks[0].(*Paragraph).Text)
	if got != "a b c" {
		t.Errorf("plain text %q", got)
	}
}

func TestFootnotes(t *testing.T) {
	doc, e := Parse([]byte("x{n|one {b|two}} y{n|three}\n"))
	if e != nil {
		t.Fatal(e)
	}
	if len(doc.Footnotes) != 2 || doc.Footnotes[1].Number != 2 {
		t.Fatalf("footnotes %+v", doc.Footnotes)
	}
	if PlainText(doc.Footnotes[0].Text) != "one two" {
		t.Errorf("footnote text %q", PlainText(doc.Footnotes[0].Text))
	}
	if !doc.Footnotes[0].Text[4].Style.Bold {
		t.Error("bold lost in footnote")
	}
}

func TestStructure(t *testing.T) {
	src := "@doc\ntitle = T\n@end\n@toc title=\"My Toc\"\n@ol start=3\n@li one\ncont\n@ul\n@li inner\n@end\n@li two\n@end\n"
	doc, e := Parse([]byte(src))
	if e != nil {
		t.Fatal(e)
	}
	if doc.Meta.Title != "T" || doc.TOC == nil || doc.TOC.Title != "My Toc" {
		t.Errorf("meta/toc: %+v %+v", doc.Meta, doc.TOC)
	}
	l := doc.Blocks[0].(*List)
	if !l.Ordered || l.Start != 3 || len(l.Items) != 2 {
		t.Fatalf("list %+v", l)
	}
	if PlainText(l.Items[0].Text) != "one cont" || len(l.Items[0].Children) != 1 {
		t.Errorf("item 0: %q %d", PlainText(l.Items[0].Text), len(l.Items[0].Children))
	}
}

func TestPre(t *testing.T) {
	doc, e := Parse([]byte("@pre\n  a  \n\n@h1 not a heading\n  @end  \n"))
	if e != nil {
		t.Fatal(e)
	}
	p := doc.Blocks[0].(*Pre)
	if len(p.Lines) != 3 || p.Lines[0] != "  a" || p.Lines[1] != "" || p.Lines[2] != "@h1 not a heading" {
		t.Errorf("pre lines %q", p.Lines)
	}
}
