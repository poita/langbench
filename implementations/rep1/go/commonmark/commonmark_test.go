package commonmark_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"example.com/commonmark"
	"example.com/commonmark/ast"
)

func TestToHTML(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", ""},
		{"paragraph", "hello\n", "<p>hello</p>\n"},
		{"no trailing newline", "a\nb", "<p>a\nb</p>\n"},
		{"heading and emphasis", "# T *x*\n", "<h1>T <em>x</em></h1>\n"},
		{"tight list", "- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"},
		{"loose list", "- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"},
		{"ordered start", "3. a\n", "<ol start=\"3\">\n<li>a</li>\n</ol>\n"},
		{"fenced info", "```go x\nA<B\n```\n", "<pre><code class=\"language-go\">A&lt;B\n</code></pre>\n"},
		{"link with title", "[a](</b c> 't')", "<p><a href=\"/b%20c\" title=\"t\">a</a></p>\n"},
		{"image alt", "![a *b* `c`](/i)", "<p><img src=\"/i\" alt=\"a b c\" /></p>\n"},
		{"autolink", "<http://x.y/?a=1&b>", "<p><a href=\"http://x.y/?a=1&amp;b\">http://x.y/?a=1&amp;b</a></p>\n"},
		{"email autolink", "<a@b.co>", "<p><a href=\"mailto:a@b.co\">a@b.co</a></p>\n"},
		{"unsafe url", "[x](javascript:alert(1))", "<p><a href=\"\">x</a></p>\n"},
		{"hard break", "a  \nb\\\nc", "<p>a<br />\nb<br />\nc</p>\n"},
		{"entities", "&amp; &#65; &#0; &copy;", "<p>&amp; A � &amp;copy;</p>\n"},
		{"unmatched bracket", "[a] b", "<p>[a] b</p>\n"},
		{"setext", "a\nb\n===\n", "<h1>a\nb</h1>\n"},
		{"lazy quote", "> a\nb\n", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n"},
		{"rule of three", "*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n"},
		{"link in link", "[x [a](/b) y](/d)", "<p>[x <a href=\"/b\">a</a> y](/d)</p>\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := commonmark.ToHTML(tc.in); got != tc.want {
				t.Errorf("ToHTML(%q)\n got: %q\nwant: %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestParseTree(t *testing.T) {
	doc := commonmark.Parse("> a *b*\n")
	bq := doc.FirstChild
	if bq == nil || bq.Kind != ast.BlockQuote {
		t.Fatalf("first child = %v, want block quote", bq)
	}
	para := bq.FirstChild
	if para.Kind != ast.Paragraph {
		t.Fatalf("got %v, want paragraph", para.Kind)
	}
	var kinds []string
	for c := para.FirstChild; c != nil; c = c.Next {
		kinds = append(kinds, c.Kind.String())
	}
	if got, want := strings.Join(kinds, ","), "text,emph"; got != want {
		t.Errorf("inline kinds = %s, want %s", got, want)
	}
}

// TestDeepAndPathological checks that nesting and adversarial inputs neither
// overflow the stack nor take quadratic time.
func TestDeepAndPathological(t *testing.T) {
	inputs := map[string]string{
		"nested emphasis":   strings.Repeat("*a ", 20000) + "b" + strings.Repeat("*", 20000),
		"brackets":          strings.Repeat("[", 50000) + strings.Repeat("]", 50000),
		"nested links":      strings.Repeat("[a", 20000) + strings.Repeat("](/u)", 20000),
		"nested images":     strings.Repeat("![a ", 20000) + strings.Repeat("](/x)", 20000),
		"block quotes":      strings.Repeat(">", 300) + " x\n",
		"unclosed titles":   strings.Repeat("[a](/u \"", 50000),
		"backtick runs":     strings.Repeat("`` ` ``` ` ", 50000),
		"underscore runs":   strings.Repeat("_a__ ", 40000),
		"nested list items": strings.Join(repeatIndented(300), "\n"),
	}
	for name, in := range inputs {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			commonmark.ToHTML(in)
			if d := time.Since(start); d > 5*time.Second {
				t.Errorf("took %v", d)
			}
		})
	}
}

func repeatIndented(n int) []string {
	lines := make([]string, n)
	for i := range lines {
		lines[i] = strings.Repeat("  ", i) + "- a"
	}
	return lines
}

func ExampleToHTML() {
	fmt.Print(commonmark.ToHTML("Hello, *world*!"))
	// Output:
	// <p>Hello, <em>world</em>!</p>
}
