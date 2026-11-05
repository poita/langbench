package commonmark_test

import (
	"testing"

	"example.com/commonmark"
)

type convCase struct {
	name, in, want string
}

func runCases(t *testing.T, cases []convCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := commonmark.ToHTMLString(c.in); got != c.want {
				t.Errorf("input: %q\nwant:  %q\ngot:   %q", c.in, c.want, got)
			}
		})
	}
}

func TestEmpty(t *testing.T) {
	runCases(t, []convCase{
		{"empty", "", ""},
		{"newline", "\n", ""},
		{"blank lines", "\n  \n\t\n", ""},
	})
}

func TestParagraphsAndHeadings(t *testing.T) {
	runCases(t, []convCase{
		{"paragraph", "foo\nbar\n", "<p>foo\nbar</p>\n"},
		{"two paragraphs", "a\n\nb", "<p>a</p>\n<p>b</p>\n"},
		{"leading spaces stripped", "  a\n   b", "<p>a\nb</p>\n"},
		{"atx", "# foo #\n## bar ##   \n#\n", "<h1>foo</h1>\n<h2>bar</h2>\n<h1></h1>\n"},
		{"atx closing needs space", "# foo#\n# foo \\#\n", "<h1>foo#</h1>\n<h1>foo #</h1>\n"},
		{"atx all hashes", "### ###\n# #\n", "<h3></h3>\n<h1></h1>\n"},
		{"seven hashes", "####### x", "<p>####### x</p>\n"},
		{"setext", "Foo\n===\nBar\n---\n", "<h1>Foo</h1>\n<h2>Bar</h2>\n"},
		{"multiline setext", "a\nb\n---", "<h2>a\nb</h2>\n"},
		{"thematic", "***\n---\n___\n- - -\n", "<hr />\n<hr />\n<hr />\n<hr />\n"},
		{"setext beats hr", "a\n---", "<h2>a</h2>\n"},
	})
}

func TestCodeBlocks(t *testing.T) {
	runCases(t, []convCase{
		{"indented", "    a\n\n\n    b\n", "<pre><code>a\n\n\nb\n</code></pre>\n"},
		{"indented keeps trailing spaces", "    foo  \n", "<pre><code>foo  \n</code></pre>\n"},
		{"indent cannot interrupt paragraph", "a\n    b", "<p>a\nb</p>\n"},
		{"tab", "\tfoo\tbaz\n", "<pre><code>foo\tbaz\n</code></pre>\n"},
		{"fenced", "```\n<\n>\n```\n", "<pre><code>&lt;\n&gt;\n</code></pre>\n"},
		{"fenced info", "```ruby x\ndef\n```\n", "<pre><code class=\"language-ruby\">def\n</code></pre>\n"},
		{"info language prefix", "```language-go\n```\n", "<pre><code class=\"language-go\"></code></pre>\n"},
		{"info escapes", "``` a&amp;b\\*\n```", "<pre><code class=\"language-a&amp;b*\"></code></pre>\n"},
		{"tilde", "~~~\na\n~~~\n", "<pre><code>a\n</code></pre>\n"},
		{"unclosed", "```\na\n", "<pre><code>a\n</code></pre>\n"},
		{"fence indent removed", "  ```\n  a\n   b\n c\n  ```", "<pre><code>a\n b\nc\n</code></pre>\n"},
		{"short closing fence ignored", "````\na\n```\n````", "<pre><code>a\n```\n</code></pre>\n"},
		{"backtick info with backtick", "``` a`b\nc", "<p>``` a`b\nc</p>\n"},
	})
}

func TestBlockQuotes(t *testing.T) {
	runCases(t, []convCase{
		{"simple", "> a\n> b", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n"},
		{"lazy", "> a\nb", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n"},
		{"no lazy after blank", "> a\n\nb", "<blockquote>\n<p>a</p>\n</blockquote>\n<p>b</p>\n"},
		{"nested", "> > a", "<blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n</blockquote>\n"},
		{"hr ends quote", "> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n"},
		{"code in quote", ">     a", "<blockquote>\n<pre><code>a\n</code></pre>\n</blockquote>\n"},
		{"empty", ">", "<blockquote>\n</blockquote>\n"},
		{"interrupts paragraph", "a\n> b", "<p>a</p>\n<blockquote>\n<p>b</p>\n</blockquote>\n"},
	})
}

func TestLists(t *testing.T) {
	runCases(t, []convCase{
		{"tight bullets", "- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"},
		{"loose bullets", "- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"},
		{"ordered", "1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n"},
		{"ordered start", "3. a\n4. b", "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n"},
		{"ordered start zero", "0) a", "<ol start=\"0\">\n<li>a</li>\n</ol>\n"},
		{"leading zeros", "003. a", "<ol start=\"3\">\n<li>a</li>\n</ol>\n"},
		{"ten digits is text", "1234567890. a", "<p>1234567890. a</p>\n"},
		{"bullet change", "- a\n+ b\n", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n"},
		{"delimiter change", "1. a\n2) b\n", "<ol>\n<li>a</li>\n</ol>\n<ol start=\"2\">\n<li>b</li>\n</ol>\n"},
		{"nested", "- a\n  - b\n", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n"},
		{"empty item", "-\n- b", "<ul>\n<li></li>\n<li>b</li>\n</ul>\n"},
		{"code in item", "- a\n\n      b\n", "<ul>\n<li>\n<p>a</p>\n<pre><code>b\n</code></pre>\n</li>\n</ul>\n"},
		{"fenced in item", "- ```\n  x\n  ```\n", "<ul>\n<li>\n<pre><code>x\n</code></pre>\n</li>\n</ul>\n"},
		{"only 1 interrupts paragraph", "a\n2. b", "<p>a\n2. b</p>\n"},
		{"1 interrupts paragraph", "a\n1. b", "<p>a</p>\n<ol>\n<li>b</li>\n</ol>\n"},
		{"empty cannot interrupt", "a\n-\nb", "<h2>a</h2>\n<p>b</p>\n"},
		{"star hr not item", "* a\n***\n", "<ul>\n<li>a</li>\n</ul>\n<hr />\n"},
		{"blank inside nested makes loose", "- a\n  - b\n\n    c\n- d", "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n"},
		{"blank inside fence stays tight", "- ```\n  a\n\n  b\n  ```\n- c", "<ul>\n<li>\n<pre><code>a\n\nb\n</code></pre>\n</li>\n<li>c</li>\n</ul>\n"},
		{"tab after marker", "-\ta", "<ul>\n<li>a</li>\n</ul>\n"},
		{"five spaces is code", "-     a", "<ul>\n<li>\n<pre><code>a\n</code></pre>\n</li>\n</ul>\n"},
	})
}

func TestTabs(t *testing.T) {
	runCases(t, []convCase{
		{"tab list continuation", "  - foo\n\n\tbar\n", "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n"},
		{"partial tab in code", "- foo\n\n\t\tbar\n", "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n"},
		{"quote with tab", ">\t\tfoo\n", "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n"},
	})
}
