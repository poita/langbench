package block

import (
	"strings"
	"testing"

	"example.com/commonmark/ast"
)

// shape renders the block tree as nested kind names, e.g. "bq(p)".
func shape(n *ast.Node) string {
	names := map[ast.Kind]string{
		ast.Document: "doc", ast.BlockQuote: "bq", ast.List: "list", ast.Item: "li",
		ast.Paragraph: "p", ast.Heading: "h", ast.ThematicBreak: "hr", ast.CodeBlock: "code",
	}
	var parts []string
	for c := n.FirstChild; c != nil; c = c.Next {
		parts = append(parts, shape(c))
	}
	s := names[n.Kind]
	if len(parts) > 0 {
		s += "(" + strings.Join(parts, " ") + ")"
	}
	return s
}

func TestStructure(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", "doc"},
		{"paragraphs", "a\n\nb\n", "doc(p p)"},
		{"quote lazy", "> a\nb\n", "doc(bq(p))"},
		{"quote then hr", "> a\n---\n", "doc(bq(p) hr)"},
		{"list then hr", "- a\n---\n", "doc(list(li(p)) hr)"},
		{"setext", "a\n---\n", "doc(h)"},
		{"nested list", "- a\n  - b\n", "doc(list(li(p list(li(p)))))"},
		{"bullet change", "- a\n* b\n", "doc(list(li(p)) list(li(p)))"},
		{"code after para", "a\n    b\n", "doc(p)"},
		{"indented code", "    a\n", "doc(code)"},
		{"fence", "```\na\n```\nb\n", "doc(code p)"},
		{"ordered interrupts only with 1", "a\n2. b\n", "doc(p)"},
		{"ordered 1 interrupts", "a\n1. b\n", "doc(p list(li(p)))"},
		{"empty item", "-\n", "doc(list(li))"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := shape(Parse(tc.in)); got != tc.want {
				t.Errorf("Parse(%q) shape = %s, want %s", tc.in, got, tc.want)
			}
		})
	}
}

func TestTightness(t *testing.T) {
	tests := []struct {
		in    string
		tight bool
	}{
		{"- a\n- b\n", true},
		{"- a\n\n- b\n", false},
		{"- a\n\n  b\n", false},
		{"- a\n  - b\n\n  - c\n- d\n", true},
		{"- ```\n  a\n\n  ```\n- b\n", true},
		{"- a\n  ***\n\n- b\n", true},
	}
	for _, tc := range tests {
		doc := Parse(tc.in)
		if got := doc.FirstChild.List.Tight; got != tc.tight {
			t.Errorf("Parse(%q) tight = %v, want %v", tc.in, got, tc.tight)
		}
	}
}

func TestCodeAndHeadingData(t *testing.T) {
	doc := Parse("```  go&amp;\\* x \n  a\n b\n```\n")
	c := doc.FirstChild
	if c.Info != "go&* x" || c.Literal != "  a\n b\n" {
		t.Errorf("info %q literal %q", c.Info, c.Literal)
	}
	doc = Parse("    a  \n\n    \n    b\n\n")
	if got := doc.FirstChild.Literal; got != "a  \n\n\nb\n" {
		t.Errorf("indented literal %q", got)
	}
	for in, want := range map[string]string{
		"# foo #\n": "foo\n", "# foo ###   \n": "foo\n", "# #\n": "\n", "### ###\n": "\n",
		"# foo#\n": "foo#\n", "#\n": "",
	} {
		h := Parse(in).FirstChild
		if h.Kind != ast.Heading || string(h.State.Content) != want {
			t.Errorf("Parse(%q) content %q, want %q", in, h.State.Content, want)
		}
	}
}

func TestStartNumber(t *testing.T) {
	l := Parse("003. a\n").FirstChild
	if l.List.Type != ast.Ordered || l.List.Start != 3 || l.List.Delim != '.' {
		t.Errorf("list data %+v", l.List)
	}
}
