package inline_test

import (
	"strings"
	"testing"

	"example.com/commonmark/ast"
	"example.com/commonmark/block"
	"example.com/commonmark/inline"
)

// dump prints the inline children of the first paragraph as a compact
// s-expression-like string.
func dump(n *ast.Node) string {
	var b strings.Builder
	for c := n.FirstChild; c != nil; c = c.Next {
		switch c.Kind {
		case ast.Text:
			b.WriteString(c.Literal)
		case ast.Softbreak:
			b.WriteString("<sb>")
		case ast.Linebreak:
			b.WriteString("<lb>")
		case ast.Code:
			b.WriteString("`" + c.Literal + "`")
		default:
			b.WriteString("(" + c.Kind.String())
			if c.Kind == ast.Link || c.Kind == ast.Image {
				b.WriteString(" " + c.Dest)
				if c.HasTitle {
					b.WriteString(" t=" + c.Title)
				}
			}
			b.WriteString(" " + dump(c) + ")")
		}
	}
	return b.String()
}

func TestParse(t *testing.T) {
	tests := []struct{ in, want string }{
		{"a*b*c", "a(emph b)c"},
		{"**a**", "(strong a)"},
		{"***a***", "(emph (strong a))"},
		{"a_b_c", "a_b_c"},
		{"foo\\\nbar", "foo<lb>bar"},
		{"foo  \nbar", "foo<lb>bar"},
		{"foo \nbar", "foo<sb>bar"},
		{"`` a ` b ``", "`a ` b`"},
		{"` `` `", "````"}, // code span "``"
		{"``a", "``a"},
		{"[a](/u \"t\")", "(link /u t=t a)"},
		{"[a](<>)", "(link  a)"},
		{"[a](/u 'x\\'y')", "(link /u t=x'y a)"},
		{"[a](/u (x))", "(link /u t=x a)"},
		{"[a](/u\"x\")", "(link /u\"x\" a)"},
		{"[a](/my uri)", "[a](/my uri)"},
		{"[a](/u\\*&amp;)", "(link /u*& a)"},
		{"![a](/i)", "(image /i a)"},
		{"[a]", "[a]"},
		{"<http://a.b>", "(link http://a.b http://a.b)"},
		{"<a@b.c>", "(link mailto:a@b.c a@b.c)"},
		{"<http://a b>", "<http://a b>"},
		{"<a@-b.c>", "<a@-b.c>"},
		{"&#35;&bogus;", "#&bogus;"},
		{"\\*a\\", "*a\\"},
		{"[x [a](/b) y](/d)", "[x (link /b a) y](/d)"},
		{"[x [a](/b) ![i [q] j](/k) y](/d)", "(link /d x (link /b a) (image /k i [q] j) y)"},
		{"*foo**bar**baz*", "(emph foo(strong bar)baz)"},
		{"*(*foo)", "*(*foo)"},
		{"a * b", "a * b"},
	}
	for _, tc := range tests {
		doc := block.Parse(tc.in)
		inline.ParseAll(doc)
		para := doc.FirstChild
		if got := dump(para); got != tc.want {
			t.Errorf("inline(%q)\n got: %s\nwant: %s", tc.in, got, tc.want)
		}
	}
}

func TestCodeSpanSearch(t *testing.T) {
	doc := block.Parse("`a ``b` ``` c ``\n")
	inline.ParseAll(doc)
	c := doc.FirstChild.FirstChild
	if c.Kind != ast.Code || c.Literal != "a ``b" {
		t.Fatalf("first inline = %v %q, want code span %q", c.Kind, c.Literal, "a ``b")
	}
	// The remaining runs have no partner of equal length: plain text.
	if got := dump(doc.FirstChild); got != "`a ``b` ``` c ``" {
		t.Errorf("got %s", got)
	}
}
