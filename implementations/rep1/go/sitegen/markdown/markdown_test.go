package markdown

import (
	"strings"
	"testing"
	"time"
)

func TestToHTML(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"empty", "", ""},
		{"only blank lines", "\n\n  \n", ""},
		{"paragraph", "hello\n", "<p>hello</p>\n"},
		{"no trailing newline", "hello", "<p>hello</p>\n"},
		{"two paragraphs", "a\n\nb", "<p>a</p>\n<p>b</p>\n"},
		{"soft break", "a\nb", "<p>a\nb</p>\n"},
		{"hard break spaces", "a  \nb", "<p>a<br />\nb</p>\n"},
		{"hard break backslash", "a\\\nb", "<p>a<br />\nb</p>\n"},
		{"one trailing space is not a break", "a \nb", "<p>a\nb</p>\n"},
		{"leading space of continuation dropped", "a\n   b", "<p>a\nb</p>\n"},

		// Blocks.
		{"atx heading", "# Title #\n", "<h1>Title</h1>\n"},
		{"atx levels", "###### six\n####### seven", "<h6>six</h6>\n<p>####### seven</p>\n"},
		{"atx closing sequence", "# foo ###   \n# foo#\n# foo \\#\n### ###\n#", "<h1>foo</h1>\n<h1>foo#</h1>\n<h1>foo #</h1>\n<h3></h3>\n<h1></h1>\n"},
		{"atx needs space", "#foo", "<p>#foo</p>\n"},
		{"setext", "Foo\n---\n\nBar\n===", "<h2>Foo</h2>\n<h1>Bar</h1>\n"},
		{"setext multi-line", "a\nb\n---", "<h2>a\nb</h2>\n"},
		{"thematic breaks", "***\n---\n___\n- - -", "<hr />\n<hr />\n<hr />\n<hr />\n"},
		{"indented code", "    a < b\n\n    c\n", "<pre><code>a &lt; b\n\nc\n</code></pre>\n"},
		{"indented code trailing blank lines", "    a\n\n\n", "<pre><code>a\n</code></pre>\n"},
		{"indented line continues paragraph", "a\n    b", "<p>a\nb</p>\n"},
		{"fenced code", "```go\nx := 1\n```\n", "<pre><code class=\"language-go\">x := 1\n</code></pre>\n"},
		{"fenced tilde unclosed", "~~~\na\n\nb", "<pre><code>a\n\nb\n</code></pre>\n"},
		{"fence info language prefix", "```language-foo bar\nx\n```", "<pre><code class=\"language-foo\">x\n</code></pre>\n"},
		{"fence info entity and escape", "``` a&amp;b\\*c\nx\n```", "<pre><code class=\"language-a&amp;b*c\">x\n</code></pre>\n"},
		{"fence indent removed", "  ```\n   a\n  b\n  ```", "<pre><code> a\nb\n</code></pre>\n"},
		{"backtick fence info cannot hold backtick", "``` a`b\nx", "<p>``` a`b\nx</p>\n"},
		{"empty fence", "```\n```", "<pre><code></code></pre>\n"},
		{"block quote", "> a\n> b\n\n> c", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n<blockquote>\n<p>c</p>\n</blockquote>\n"},
		{"lazy continuation", "> a\nb", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n"},
		{"quote then rule", "> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n"},
		{"nested quote", "> > a", "<blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n</blockquote>\n"},
		{"tab after quote marker", ">\ta", "<blockquote>\n<p>a</p>\n</blockquote>\n"},
		{"tab indented code", "\tcode", "<pre><code>code\n</code></pre>\n"},
		{"tab partially consumed", ">\t\tfoo", "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n"},

		// Lists.
		{"tight bullet list", "- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"},
		{"loose bullet list", "- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"},
		{"ordered start", "3. a\n4. b", "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n"},
		{"ordered start zero", "0. a", "<ol start=\"0\">\n<li>a</li>\n</ol>\n"},
		{"ordered one", "1) a\n2) b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n"},
		{"bullet change starts new list", "- a\n* b", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n"},
		{"nested list", "- a\n  - b\n- c", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n<li>c</li>\n</ul>\n"},
		{"empty item", "-\n- a", "<ul>\n<li></li>\n<li>a</li>\n</ul>\n"},
		{"list interrupts paragraph only with 1", "a\n2. b", "<p>a\n2. b</p>\n"},
		{"list interrupts paragraph", "a\n1. b", "<p>a</p>\n<ol>\n<li>b</li>\n</ol>\n"},
		{"empty bullet does not interrupt", "a\n-\nb", "<h2>a</h2>\n<p>b</p>\n"},
		{"code in item", "- a\n\n      code", "<ul>\n<li>\n<p>a</p>\n<pre><code>code\n</code></pre>\n</li>\n</ul>\n"},
		{"item with fenced code", "- ```\n  x\n  ```\n- b", "<ul>\n<li>\n<pre><code>x\n</code></pre>\n</li>\n<li>b</li>\n</ul>\n"},
		{"loose by nested blank", "- a\n  - b\n\n  - c\n- d", "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n"},
		{"two blank lines split lists? no", "- a\n\n\n- b", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"},
		{"blank in fence does not loosen", "- ```\n\n  ```\n- b", "<ul>\n<li>\n<pre><code>\n</code></pre>\n</li>\n<li>b</li>\n</ul>\n"},

		// Inlines.
		{"emphasis", "*a* _b_ **c** __d__", "<p><em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong></p>\n"},
		{"rule of three", "*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n"},
		{"intraword underscore", "a_b_c", "<p>a_b_c</p>\n"},
		{"intraword star", "a*b*c", "<p>a<em>b</em>c</p>\n"},
		{"triple", "***a***", "<p><em><strong>a</strong></em></p>\n"},
		{"unmatched", "*a", "<p>*a</p>\n"},
		{"flanking space", "a * b *", "<p>a * b *</p>\n"},
		{"nested strong", "**a *b* c**", "<p><strong>a <em>b</em> c</strong></p>\n"},
		{"code span", "`a  b`", "<p><code>a  b</code></p>\n"},
		{"code span strip one space", "`` ` ``", "<p><code>`</code></p>\n"},
		{"code span all spaces", "`  `", "<p><code>  </code></p>\n"},
		{"code span newline", "`a\nb`", "<p><code>a b</code></p>\n"},
		{"code span unmatched", "```a``", "<p>```a``</p>\n"},
		{"code span escape not processed", "`\\*`", "<p><code>\\*</code></p>\n"},
		{"backslash escape", "\\*a\\* \\a", "<p>*a* \\a</p>\n"},
		{"entities", "&amp; &lt; &#65; &#x42; &#0; &copy; &#12345678;", "<p>&amp; &lt; A B \uFFFD &amp;copy; &amp;#12345678;</p>\n"},
		{"escaping", "a < b > c \" d", "<p>a &lt; b &gt; c &quot; d</p>\n"},
		{"link", "[a](/b)", "<p><a href=\"/b\">a</a></p>\n"},
		{"link title", "[a](/b \"t\")", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"link title single", "[a](/b 't')", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"link title paren", "[a](/b (t))", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"link empty title", "[a](/b \"\")", "<p><a href=\"/b\" title=\"\">a</a></p>\n"},
		{"link angle dest", "[a](</my uri>)", "<p><a href=\"/my%20uri\">a</a></p>\n"},
		{"link empty dest", "[a]()", "<p><a href=\"\">a</a></p>\n"},
		{"link invalid", "[a](/my uri)", "<p>[a](/my uri)</p>\n"},
		{"link nested parens", "[a](/b(c))", "<p><a href=\"/b(c)\">a</a></p>\n"},
		{"link dest entity and escape", "[a](/b\\*&amp;&quot;)", "<p><a href=\"/b*&amp;%22\">a</a></p>\n"},
		{"link text emphasis", "[*a*](/b)", "<p><a href=\"/b\"><em>a</em></a></p>\n"},
		{"links do not nest", "[a [b](/c) d](/e)", "<p>[a <a href=\"/c\">b</a> d](/e)</p>\n"},
		{"reference-style is text", "[a][b] [c]", "<p>[a][b] [c]</p>\n"},
		{"javascript url", "[j](javascript:alert(1))", "<p><a href=\"\">j</a></p>\n"},
		{"data url", "[d](data:text/html,x) ![i](data:image/png;base64,AA)", "<p><a href=\"\">d</a> <img src=\"data:image/png;base64,AA\" alt=\"i\" /></p>\n"},
		{"url encoding", "[a](/é'&\"|)", "<p><a href=\"/%C3%A9&#x27;&amp;%22%7C\">a</a></p>\n"},
		{"image", "![a *b* `c`](/i.png \"t\")", "<p><img src=\"/i.png\" alt=\"a b c\" title=\"t\" /></p>\n"},
		{"image alt breaks", "![a\nb](/i)", "<p><img src=\"/i\" alt=\"a b\" /></p>\n"},
		{"image in link", "[![a](/i)](/l)", "<p><a href=\"/l\"><img src=\"/i\" alt=\"a\" /></a></p>\n"},
		{"autolink", "<http://a.b/?x=1&y=2>", "<p><a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a></p>\n"},
		{"email autolink", "<a@b.co>", "<p><a href=\"mailto:a@b.co\">a@b.co</a></p>\n"},
		{"not an autolink", "<a b> < c <1>", "<p>&lt;a b&gt; &lt; c &lt;1&gt;</p>\n"},
		{"autolink backslash literal", "<http://a\\*b>", "<p><a href=\"http://a%5C*b\">http://a\\*b</a></p>\n"},
		{"link_closed quirk", "[x [a](/b) ![i [q] j](/k) y](/d)", "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ToHTML(tc.in); got != tc.want {
				t.Errorf("ToHTML(%q)\n got: %q\nwant: %q", tc.in, got, tc.want)
			}
		})
	}
}

// The worked examples of the conversion's specification.
func TestWorkedExamples(t *testing.T) {
	in1 := "# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n- one\n- two\n  - nested\n\n1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n"
	want1 := `<h1>Title</h1>
<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href="/my%20uri" title="t&quot;x">link</a>.</p>
<ul>
<li>one</li>
<li>two
<ul>
<li>nested</li>
</ul>
</li>
</ul>
<ol>
<li>
<p>a</p>
<p>b</p>
</li>
<li>
<p>c</p>
</li>
</ol>
<blockquote>
<p>quote<br />
line<br />
	lazy</p>
</blockquote>
<pre><code>code &lt;b&gt;
</code></pre>
`
	in2 := "*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb\n"
	want2 := "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> <img src=\"/i.png\" alt=\"alt x y\" />\n" +
		"<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB\uFFFD *lit* a<br />\nb</p>\n"
	in3 := "- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n[j](javascript:alert(1)) [k](/x \"\") [](<>)\n"
	want3 := `<ul>
<li>
<p>a</p>
</li>
<li>
<pre><code class="language-py">x = &quot;&lt;&gt;&quot;
</code></pre>
</li>
<li>
<p>c</p>
<p>d</p>
</li>
</ul>
<ul>
<li>e</li>
</ul>
<hr />
<h2>Foo</h2>
<p><a href="">j</a> <a href="/x" title="">k</a> <a href=""></a></p>
`
	for i, tc := range []struct{ in, want string }{{in1, want1}, {in2, want2}, {in3, want3}} {
		if got := ToHTML(tc.in); got != tc.want {
			t.Errorf("example %d:\n got: %q\nwant: %q", i+1, got, tc.want)
		}
	}
}

func TestDeepNesting(t *testing.T) {
	// Deeply nested emphasis, brackets and block quotes must not overflow or
	// take quadratic time.
	const n = 5000
	src := strings.Repeat("*a ", n) + strings.Repeat("a* ", n)
	_ = ToHTML(src)
	src = strings.Repeat("[", n) + strings.Repeat("]", n)
	if got := ToHTML(src); got != "<p>"+src+"</p>\n" {
		t.Errorf("brackets: unexpected output of length %d", len(got))
	}
	src = strings.Repeat("> ", 300) + "x"
	got := ToHTML(src)
	if strings.Count(got, "<blockquote>") != 300 {
		t.Errorf("block quotes: got %d", strings.Count(got, "<blockquote>"))
	}
	src = strings.Repeat("_a ", n) + strings.Repeat("**b ", n)
	_ = ToHTML(src)
}

func BenchmarkToHTML(b *testing.B) {
	para := "Some *emphasis*, **strong**, `code` and a [link](/x \"t\") with <http://a.b> text.\n"
	src := strings.Repeat(para, 5000)
	b.SetBytes(int64(len(src)))
	for b.Loop() {
		ToHTML(src)
	}
}

// TestLargeInputs guards against quadratic behaviour on the pathological
// inputs the converter is designed for.
func TestLargeInputs(t *testing.T) {
	cases := map[string]string{
		"fenced block":       "```\n" + strings.Repeat("some code line\n", 50000) + "```\n",
		"ordered list":       strings.Repeat("1. item [link](/x) `code`\n", 12000),
		"one paragraph":      strings.Repeat("word *emph* and **strong** text ", 12000),
		"unmatched brackets": strings.Repeat("[", 5000) + strings.Repeat("]", 5000),
		"underscore runs":    strings.Repeat("_a ", 8000),
		"star runs":          strings.Repeat("**a ", 12000),
		"backtick runs":      strings.Repeat("` `` ``` ```` ", 4000),
		"nested lists":       nestedLists(300),
		"nested quotes":      strings.Repeat("> ", 300) + "deep\n",
		"link openers":       strings.Repeat("[a](", 5000),
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			ToHTML(src)
			if d := time.Since(start); d > 2*time.Second {
				t.Errorf("took %v", d)
			}
		})
	}
}

func nestedLists(depth int) string {
	var b strings.Builder
	for i := 0; i < depth; i++ {
		b.WriteString(strings.Repeat("  ", i) + "- item\n")
	}
	return b.String()
}
