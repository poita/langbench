package markup

import "testing"

func parse(t *testing.T, src string) *Document {
	t.Helper()
	d, err := Parse([]byte(src))
	if err != nil {
		t.Fatalf("unexpected error %v for %q", err, src)
	}
	return d
}

func TestParagraphAndInline(t *testing.T) {
	d := parse(t, "Hello  {b|bold} world~x\\ y\\-z.\n  second\nline\n\nNext.\n")
	if len(d.Blocks) != 2 || d.Paragraphs != 2 {
		t.Fatalf("blocks = %d paragraphs = %d", len(d.Blocks), d.Paragraphs)
	}
	p := d.Blocks[0].(*Paragraph)
	var kinds []UnitKind
	for _, u := range p.Text {
		kinds = append(kinds, u.Kind)
	}
	// Hello, one glue, bold, glue, world, rigid, x, rigid, y, disc, z . glue second glue line
	glue := 0
	for _, k := range kinds {
		if k == UGlue {
			glue++
		}
	}
	if glue != 4 {
		t.Errorf("want 4 glues (runs collapsed, lines joined), got %d", glue)
	}
	if PlainText(p.Text) != "Hello bold world x yz. second line" {
		t.Errorf("plain text = %q", PlainText(p.Text))
	}
}

func TestFootnoteAndStyle(t *testing.T) {
	d := parse(t, "A{n|note {i|it}} b\n")
	if len(d.Footnotes) != 1 {
		t.Fatal("expected one footnote")
	}
	p := d.Blocks[0].(*Paragraph)
	if p.Text[1].Kind != UMark || p.Text[1].Aux != 1 {
		t.Errorf("mark missing: %+v", p.Text)
	}
	if PlainText(d.Footnotes[0]) != "note it" {
		t.Errorf("footnote text = %q", PlainText(d.Footnotes[0]))
	}
	last := d.Footnotes[0][len(d.Footnotes[0])-1]
	if !d.StyleOf(last.Style).Italic {
		t.Error("italic style lost in footnote")
	}
}

func TestStructure(t *testing.T) {
	src := "@doc\ntitle = T\nauthor = A\n@end\n@toc title=\"My Contents\"\n@h1 One\n@ul\n@li a\ncont\n@q\nquoted\n@end\n@li b\n@end\n" +
		"@table cols=2 align=lr\nx | y\n@hrule\n1 | 2\n@end\n@pre\n  raw  \n\n@end\n@fig height=10pt\ncap\n\nmore\n@end\n@rule\n@vspace height=3pt\n@newpage\n"
	d := parse(t, src)
	if d.Meta.Title != "T" || d.Meta.Author != "A" || !d.HasTOC || d.TOCTitle != "My Contents" {
		t.Errorf("meta/toc wrong: %+v", d)
	}
	l := d.Blocks[1].(*List)
	if len(l.Items) != 2 || PlainText(l.Items[0].Text) != "a cont" || len(l.Items[0].Children) != 1 {
		t.Errorf("list wrong: %+v", l)
	}
	tb := d.Blocks[2].(*Table)
	if tb.Cols != 2 || len(tb.Elems) != 3 || !tb.Elems[1].Rule {
		t.Errorf("table wrong: %+v", tb)
	}
	pre := d.Blocks[3].(*Pre)
	if len(pre.Lines) != 2 || pre.Lines[0] != "  raw" || pre.Lines[1] != "" {
		t.Errorf("pre lines = %q", pre.Lines)
	}
	fg := d.Blocks[4].(*Figure)
	if fg.Height != 10000 || PlainText(fg.Caption) != "cap more" {
		t.Errorf("figure wrong: %+v", fg)
	}
	if d.Headings != 1 || d.Tables != 1 || d.Figures != 1 {
		t.Errorf("counts wrong: %+v", d)
	}
}

func TestErrors(t *testing.T) {
	cases := []struct {
		src       string
		line, col int
		code      string
	}{
		{"@h1 Title\n{z|oops}\n", 2, 1, "unknown-inline"},
		{"a {b|c\n", 1, 3, "unclosed-inline"},
		{"a }\n", 1, 3, "stray-brace"},
		{"a \\q\n", 1, 3, "bad-escape"},
		{"abc\\\n", 1, 4, "bad-escape"},
		{"@bogus\n", 1, 1, "unknown-block"},
		{"@h1x\n", 1, 1, "unknown-block"},
		{"@hrule\n", 1, 1, "block-not-allowed"},
		{"@end\n", 1, 1, "unexpected-end"},
		{"@q\ntext\n", 3, 1, "missing-end"},
		{"@toc\n@toc\n", 2, 1, "duplicate-toc"},
		{"@table cols=2\na\n@end\n", 2, 1, "cell-count"},
		{"@table align=xyz\n", 1, 1, "missing-attribute"},
		{"@table cols=0 foo=1\n", 1, 15, "bad-attribute"},
		{"@fig height=1pt\n@vspace height=1pt\n@end\n", 2, 1, "block-not-allowed"},
		{"@fig height=1pt width=\"10pt\"x\n@end\n", 1, 23, "bad-attribute-value"},
		{"@ul\ntext\n@end\n", 2, 1, "text-not-allowed"},
		{"@doc\nfoo = 1\n@end\n", 2, 1, "unknown-meta"},
		{"@doc\ntitle = 1\ntitle = 2\n@end\n", 3, 1, "duplicate-meta"},
		{"A{n|x{n|y}}\n", 1, 6, "nested-footnote"},
		{"@h1 A{n|x}\n", 1, 6, "footnote-not-allowed"},
	}
	for _, c := range cases {
		_, err := Parse([]byte(c.src))
		if err == nil {
			t.Errorf("%q: no error, want %s", c.src, c.code)
			continue
		}
		if err.Line != c.line || err.Col != c.col || err.Code != c.code || err.File != "document.cdx" {
			t.Errorf("%q: got %v want %d:%d %s", c.src, err, c.line, c.col, c.code)
		}
	}
}
