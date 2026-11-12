package render

import (
	"testing"

	"example.com/commonmark/ast"
)

func TestHref(t *testing.T) {
	tests := []struct{ in, want string }{
		{"/a b", "/a%20b"},
		{"/a%20b", "/a%20b"},
		{"/?a=1&b='", "/?a=1&amp;b=&#x27;"},
		{"/é\"<>[]\\^`{|}", "/%C3%A9%22%3C%3E%5B%5D%5C%5E%60%7B%7C%7D"},
		{"JavaScript:alert(1)", ""},
		{"vbscript:x", ""},
		{"file:///etc/passwd", ""},
		{"data:text/html,x", ""},
		{"DATA:image/PNG;base64,AA", "DATA:image/PNG;base64,AA"},
		{"javascript", "javascript"},
	}
	for _, tc := range tests {
		r := &renderer{}
		r.href(tc.in)
		if got := string(r.buf); got != tc.want {
			t.Errorf("href(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestEscape(t *testing.T) {
	r := &renderer{}
	r.escape(`<a href="x">&'é</a>`)
	if got, want := string(r.buf), `&lt;a href=&quot;x&quot;&gt;&amp;'é&lt;/a&gt;`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestDeepInlineNesting(t *testing.T) {
	doc := ast.New(ast.Document)
	p := ast.New(ast.Paragraph)
	doc.AppendChild(p)
	parent := p
	for i := 0; i < 100000; i++ {
		em := ast.New(ast.Emph)
		parent.AppendChild(em)
		parent = em
	}
	parent.AppendChild(&ast.Node{Kind: ast.Text, Literal: "x"})
	if out := HTML(doc); len(out) != len("<p>")+100000*len("<em></em>")+1+len("</p>\n") {
		t.Errorf("unexpected output length %d", len(out))
	}
}
