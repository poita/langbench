package markdown

import "testing"

func TestToHTML(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", ""},
		{"blank only", "\n  \n", ""},
		{"paragraph without newline", "hello", "<p>hello</p>\n"},
		{"heading", "# Hi #\n", "<h1>Hi</h1>\n"},
		{"setext", "Foo\n---\n", "<h2>Foo</h2>\n"},
		{"emphasis", "*a* **b**", "<p><em>a</em> <strong>b</strong></p>\n"},
		{"code span", "` a `` b `", "<p><code>a `` b</code></p>\n"},
		{"link", `[x](/u "t")`, "<p><a href=\"/u\" title=\"t\">x</a></p>\n"},
		{"image alt", "![a *b*](/i.png)", "<p><img src=\"/i.png\" alt=\"a b\" /></p>\n"},
		{"autolink", "<http://a.b/c>", "<p><a href=\"http://a.b/c\">http://a.b/c</a></p>\n"},
		{"email autolink", "<x@y.zz>", "<p><a href=\"mailto:x@y.zz\">x@y.zz</a></p>\n"},
		{"hard break", "a  \nb", "<p>a<br />\nb</p>\n"},
		{"soft break", "a\nb", "<p>a\nb</p>\n"},
		{"escape", `\*x\*`, "<p>*x*</p>\n"},
		{"entities", "&amp; &#65; &#x42; &#0;", "<p>&amp; A B �</p>\n"},
		{"fenced code", "```go\nx < y\n```\n", "<pre><code class=\"language-go\">x &lt; y\n</code></pre>\n"},
		{"language prefix kept once", "```language-foo\nx\n```\n", "<pre><code class=\"language-foo\">x\n</code></pre>\n"},
		{"unclosed fence", "```\nx", "<pre><code>x\n</code></pre>\n"},
		{"indented code", "    a\n\n    b\n", "<pre><code>a\n\nb\n</code></pre>\n"},
		{"block quote", "> a\nb\n", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n"},
		{"tight list", "- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"},
		{"loose list", "- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"},
		{"ordered start", "3. a\n", "<ol start=\"3\">\n<li>a</li>\n</ol>\n"},
		{"ordered one", "1. a\n", "<ol>\n<li>a</li>\n</ol>\n"},
		{"empty item", "-\n", "<ul>\n<li></li>\n</ul>\n"},
		{"thematic break", "***\n", "<hr />\n"},
		{"dangerous url", "[x](javascript:alert(1))", "<p><a href=\"\">x</a></p>\n"},
		{"url encoding", "[x](/a b/é\"<>)", "<p>[x](/a b/é&quot;&lt;&gt;)</p>\n"},
		{"url encoding in brackets", "[x](</a b/é>)", "<p><a href=\"/a%20b/%C3%A9\">x</a></p>\n"},
		{"empty title kept", `[x](/u "")`, "<p><a href=\"/u\" title=\"\">x</a></p>\n"},
		{"less-than is text", "a < b", "<p>a &lt; b</p>\n"},
		{"tab after quote", ">\tx\n", "<blockquote>\n<p>x</p>\n</blockquote>\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ToHTML(tc.in); got != tc.want {
				t.Errorf("ToHTML(%q)\n got: %q\nwant: %q", tc.in, got, tc.want)
			}
		})
	}
}

// The three worked examples of the specification.
func TestWorkedExamples(t *testing.T) {
	in1 := "# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n- one\n- two\n  - nested\n\n1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n"
	want1 := "<h1>Title</h1>\n<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>\n<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n<pre><code>code &lt;b&gt;\n</code></pre>\n"
	in2 := "*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb\n"
	want2 := "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> <img src=\"/i.png\" alt=\"alt x y\" />\n<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB� *lit* a<br />\nb</p>\n"
	in3 := "- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n[j](javascript:alert(1)) [k](/x \"\") [](<>)\n"
	want3 := "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n</code></pre>\n</li>\n<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n<h2>Foo</h2>\n<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n"
	for i, tc := range [][2]string{{in1, want1}, {in2, want2}, {in3, want3}} {
		if got := ToHTML(tc[0]); got != tc[1] {
			t.Errorf("example %d\n got: %q\nwant: %q", i+1, got, tc[1])
		}
	}
}

func TestEntityHelpers(t *testing.T) {
	tests := map[string]string{
		"a &amp; b":      "a & b",
		"&lt;&gt;&quot;": "<>\"",
		"&amp":           "&amp",
		"&#65;&#x41;":    "AA",
		"&#99999999;":    "&#99999999;",
		"&Amp;":          "&Amp;",
		"no entities":    "no entities",
	}
	for in, want := range tests {
		if got := decodeEntities(in); got != want {
			t.Errorf("decodeEntities(%q) = %q, want %q", in, got, want)
		}
	}
	if got := unescapeBackslashes(`a\*b\c\\`); got != `a*b\c\` {
		t.Errorf("unescapeBackslashes = %q", got)
	}
}

func TestDeepNestingDoesNotOverflow(t *testing.T) {
	// 300 nested block quotes and several thousand nested emphasis levels.
	in := ""
	for i := 0; i < 300; i++ {
		in += "> "
	}
	in += "x\n"
	if got := ToHTML(in); len(got) == 0 {
		t.Error("empty output for nested block quotes")
	}
	emph := ""
	for i := 0; i < 5000; i++ {
		emph += "*a "
	}
	emph += "b"
	for i := 0; i < 5000; i++ {
		emph += "* "
	}
	if got := ToHTML(emph); len(got) == 0 {
		t.Error("empty output for nested emphasis")
	}
}
