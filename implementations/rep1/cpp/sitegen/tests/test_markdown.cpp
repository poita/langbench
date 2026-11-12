#include <gtest/gtest.h>

#include "sitegen/markdown.hpp"

using sitegen::markdown_to_html;

namespace {
void expect_html(const std::string& md, const std::string& html) { EXPECT_EQ(markdown_to_html(md), html) << md; }
}  // namespace

TEST(Markdown, EmptyDocumentIsEmpty) {
  expect_html("", "");
  expect_html("\n\n  \n", "");
}

TEST(Markdown, ParagraphsAndLineBreaks) {
  expect_html("a\nb\n", "<p>a\nb</p>\n");
  expect_html("a  \nb", "<p>a<br />\nb</p>\n");
  expect_html("a\\\nb", "<p>a<br />\nb</p>\n");
  expect_html("one\n\ntwo", "<p>one</p>\n<p>two</p>\n");
  expect_html("  indented\n  more", "<p>indented\nmore</p>\n");
}

TEST(Markdown, AtxHeadings) {
  expect_html("# One\n## Two ##\n###### Six\n####### Seven", "<h1>One</h1>\n<h2>Two</h2>\n<h6>Six</h6>\n<p>####### Seven</p>\n");
  expect_html("# foo#", "<h1>foo#</h1>\n");
  expect_html("# foo \\#", "<h1>foo #</h1>\n");
  expect_html("### ###", "<h3></h3>\n");
  expect_html("#", "<h1></h1>\n");
  expect_html("#hashtag", "<p>#hashtag</p>\n");
}

TEST(Markdown, SetextHeadings) {
  expect_html("Foo\n---", "<h2>Foo</h2>\n");
  expect_html("Foo\nbar\n===", "<h1>Foo\nbar</h1>\n");
  expect_html("> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n");
  expect_html("- foo\n---", "<ul>\n<li>foo</li>\n</ul>\n<hr />\n");
}

TEST(Markdown, ThematicBreaks) {
  expect_html("***\n---\n___\n- - -\n _ _ _ ", "<hr />\n<hr />\n<hr />\n<hr />\n<hr />\n");
  expect_html("--", "<p>--</p>\n");
}

TEST(Markdown, CodeBlocks) {
  expect_html("    code <b>\n\n    more\n\ntext", "<pre><code>code &lt;b&gt;\n\nmore\n</code></pre>\n<p>text</p>\n");
  expect_html("```py\nx = 1\n```", "<pre><code class=\"language-py\">x = 1\n</code></pre>\n");
  expect_html("~~~\na\n```\n~~~", "<pre><code>a\n```\n</code></pre>\n");
  expect_html("```\nunclosed", "<pre><code>unclosed\n</code></pre>\n");
  expect_html("```language-x\n```", "<pre><code class=\"language-x\"></code></pre>\n");
  expect_html("  ```\n  a\n   b\n  ```", "<pre><code>a\n b\n</code></pre>\n");
  expect_html("    foo  \n", "<pre><code>foo  \n</code></pre>\n");
}

TEST(Markdown, BlockQuotes) {
  expect_html("> a\n> b\n\n> c", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n<blockquote>\n<p>c</p>\n</blockquote>\n");
  expect_html("> a\nlazy", "<blockquote>\n<p>a\nlazy</p>\n</blockquote>\n");
  expect_html(">> deep", "<blockquote>\n<blockquote>\n<p>deep</p>\n</blockquote>\n</blockquote>\n");
}

TEST(Markdown, TightAndLooseLists) {
  expect_html("- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
  expect_html("- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n");
  expect_html("1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n");
  expect_html("3. a\n4. b", "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n");
  expect_html("0) a", "<ol start=\"0\">\n<li>a</li>\n</ol>\n");
  expect_html("- a\n* b", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n");
}

TEST(Markdown, NestedLists) {
  expect_html("- one\n- two\n  - nested\n", "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n");
  expect_html("1. a\n\n   b\n2. c", "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n");
}

TEST(Markdown, OnlyOneInterruptsAParagraph) {
  expect_html("text\n2. two", "<p>text\n2. two</p>\n");
  expect_html("text\n1. one", "<p>text</p>\n<ol>\n<li>one</li>\n</ol>\n");
  expect_html("text\n-", "<h2>text</h2>\n");
}

TEST(Markdown, EmphasisAndStrong) {
  expect_html("*a* _b_ **c** __d__", "<p><em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong></p>\n");
  expect_html("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n");
  expect_html("snake_case_word", "<p>snake_case_word</p>\n");
  expect_html("**a *b* c**", "<p><strong>a <em>b</em> c</strong></p>\n");
  expect_html("*a", "<p>*a</p>\n");
  expect_html("***a***", "<p><em><strong>a</strong></em></p>\n");
  expect_html("2 * 3 * 4", "<p>2 * 3 * 4</p>\n");
}

TEST(Markdown, CodeSpans) {
  expect_html("`a` ``b ` c`` ` x `", "<p><code>a</code> <code>b ` c</code> <code>x</code></p>\n");
  expect_html("`  `", "<p><code>  </code></p>\n");
  expect_html("`unclosed", "<p>`unclosed</p>\n");
  expect_html("a `b\nc` d", "<p>a <code>b c</code> d</p>\n");
}

TEST(Markdown, EscapesAndEntities) {
  expect_html("\\*lit\\* \\a", "<p>*lit* \\a</p>\n");
  expect_html("&amp; &lt; &gt; &quot; &#65; &#x42; &#0; &copy; &", "<p>&amp; &lt; &gt; &quot; A B \xEF\xBF\xBD &amp;copy; &amp;</p>\n");
  expect_html("&#12345678;", "<p>&amp;#12345678;</p>\n");
  expect_html("a < b > c \"q\" 'r'", "<p>a &lt; b &gt; c &quot;q&quot; 'r'</p>\n");
}

TEST(Markdown, Links) {
  expect_html("[a](/b)", "<p><a href=\"/b\">a</a></p>\n");
  expect_html("[a](/b \"t\")", "<p><a href=\"/b\" title=\"t\">a</a></p>\n");
  expect_html("[a](/b 'it''s') [c](/d (p))", "<p>[a](/b 'it''s') <a href=\"/d\" title=\"p\">c</a></p>\n");
  expect_html("[a](</my uri>)", "<p><a href=\"/my%20uri\">a</a></p>\n");
  expect_html("[a](/my uri)", "<p>[a](/my uri)</p>\n");
  expect_html("[a]()", "<p><a href=\"\">a</a></p>\n");
  expect_html("[a](/u(x)y)", "<p><a href=\"/u(x)y\">a</a></p>\n");
  expect_html("[a](/x?a=1&b=2)", "<p><a href=\"/x?a=1&amp;b=2\">a</a></p>\n");
  expect_html("[*em*](/b)", "<p><a href=\"/b\"><em>em</em></a></p>\n");
  expect_html("[not a link] [x][y]", "<p>[not a link] [x][y]</p>\n");
  expect_html("[a](javascript:alert(1))", "<p><a href=\"\">a</a></p>\n");
  expect_html("[a](/b \"x\\\"y\")", "<p><a href=\"/b\" title=\"x&quot;y\">a</a></p>\n");
}

TEST(Markdown, LinksCannotContainLinks) {
  expect_html("[a [b](/c) d](/e)", "<p>[a <a href=\"/c\">b</a> d](/e)</p>\n");
}

TEST(Markdown, Images) {
  expect_html("![alt *x* `y`](/i.png)", "<p><img src=\"/i.png\" alt=\"alt x y\" /></p>\n");
  expect_html("![a](/i \"t\")", "<p><img src=\"/i\" alt=\"a\" title=\"t\" /></p>\n");
  expect_html("![a\nb](/i)", "<p><img src=\"/i\" alt=\"a b\" /></p>\n");
  expect_html("!x", "<p>!x</p>\n");
}

TEST(Markdown, Autolinks) {
  expect_html("<http://a.b/?x=1&y=2>", "<p><a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a></p>\n");
  expect_html("<me@example.com>", "<p><a href=\"mailto:me@example.com\">me@example.com</a></p>\n");
  expect_html("a < b", "<p>a &lt; b</p>\n");
  expect_html("<not a link>", "<p>&lt;not a link&gt;</p>\n");
}

TEST(Markdown, UrlEncoding) {
  expect_html("[a](/caf\xC3\xA9 'x')", "<p><a href=\"/caf%C3%A9\" title=\"x\">a</a></p>\n");
  expect_html("[a](</caf\xC3\xA9>)", "<p><a href=\"/caf%C3%A9\">a</a></p>\n");
  expect_html("[a](</a'b>)", "<p><a href=\"/a&#x27;b\">a</a></p>\n");
  expect_html("[a](/a%20b)", "<p><a href=\"/a%20b\">a</a></p>\n");
}

TEST(Markdown, TabsInIndentation) {
  expect_html("-\tfoo", "<ul>\n<li>foo</li>\n</ul>\n");
  expect_html("\tcode", "<pre><code>code\n</code></pre>\n");
  expect_html(">\tquote", "<blockquote>\n<p>quote</p>\n</blockquote>\n");
}

TEST(Markdown, SpecWorkedExampleOne) {
  expect_html(
      "# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n- one\n- two\n  - nested\n\n"
      "1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n",
      "<h1>Title</h1>\n"
      "<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href=\"/my%20uri\" "
      "title=\"t&quot;x\">link</a>.</p>\n"
      "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n"
      "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n"
      "<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n"
      "<pre><code>code &lt;b&gt;\n</code></pre>\n");
}

TEST(Markdown, SpecWorkedExampleThree) {
  expect_html(
      "- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n[j](javascript:alert(1)) [k](/x \"\") [](<>)\n",
      "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n</code></pre>\n</li>\n"
      "<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n<h2>Foo</h2>\n"
      "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n");
}

TEST(Markdown, DeepNestingAndLongInputsAreHandled) {
  std::string quotes(300, '>');
  quotes += " deep\n";
  EXPECT_NE(markdown_to_html(quotes).find("deep"), std::string::npos);

  std::string brackets(5000, '[');
  brackets += std::string(5000, ']');
  EXPECT_EQ(markdown_to_html(brackets), "<p>" + brackets + "</p>\n");

  std::string emph;
  for (int i = 0; i < 4000; ++i) emph += "*a ";
  emph += "b";
  for (int i = 0; i < 4000; ++i) emph += " a*";
  EXPECT_NE(markdown_to_html(emph).find("<em>"), std::string::npos);
}

TEST(Markdown, BacktickRunsMustMatchInLength) {
  expect_html("`` ` ``` `` `", "<p><code>` ```</code> `</p>\n");
  expect_html("``a` b```", "<p>``a` b```</p>\n");
}
