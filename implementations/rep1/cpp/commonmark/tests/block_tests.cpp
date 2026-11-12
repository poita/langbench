// Block structure: paragraphs, headings, breaks, code, quotes and lists.
#include "test_helpers.h"

TEST(Blocks, EmptyDocument) {
  EXPECT_HTML("", "");
  EXPECT_HTML("\n\n  \n", "");
}

TEST(Blocks, ParagraphsAndBlankLines) {
  EXPECT_HTML("a\nb\n\nc", "<p>a\nb</p>\n<p>c</p>\n");
  EXPECT_HTML("  a\n   b", "<p>a\nb</p>\n");
}

TEST(Blocks, AtxHeadings) {
  EXPECT_HTML("# a", "<h1>a</h1>\n");
  EXPECT_HTML("###### a", "<h6>a</h6>\n");
  EXPECT_HTML("####### a", "<p>####### a</p>\n");
  EXPECT_HTML("#a", "<p>#a</p>\n");
  EXPECT_HTML("# foo ###   ", "<h1>foo</h1>\n");
  EXPECT_HTML("# foo#", "<h1>foo#</h1>\n");
  EXPECT_HTML("# foo \\#", "<h1>foo #</h1>\n");
  EXPECT_HTML("#", "<h1></h1>\n");
  EXPECT_HTML("### ###", "<h3></h3>\n");
  EXPECT_HTML("# #", "<h1></h1>\n");
}

TEST(Blocks, SetextHeadings) {
  EXPECT_HTML("a\n===", "<h1>a</h1>\n");
  EXPECT_HTML("a\nb\n---", "<h2>a\nb</h2>\n");
  EXPECT_HTML("a\n-", "<h2>a</h2>\n");
  EXPECT_HTML("> a\n---", "<blockquote>\n<p>a</p>\n</blockquote>\n<hr />\n");
  EXPECT_HTML("- a\n---", "<ul>\n<li>a</li>\n</ul>\n<hr />\n");
}

TEST(Blocks, ThematicBreaks) {
  EXPECT_HTML("***\n---\n___", "<hr />\n<hr />\n<hr />\n");
  EXPECT_HTML(" - - -", "<hr />\n");
  EXPECT_HTML("--", "<p>--</p>\n");
  EXPECT_HTML("    ---", "<pre><code>---\n</code></pre>\n");
}

TEST(Blocks, IndentedCode) {
  EXPECT_HTML("    a\n\n\n    b\n", "<pre><code>a\n\n\nb\n</code></pre>\n");
  EXPECT_HTML("    foo  ", "<pre><code>foo  \n</code></pre>\n");
  EXPECT_HTML("para\n    not code", "<p>para\nnot code</p>\n");
  EXPECT_HTML("\ta\n", "<pre><code>a\n</code></pre>\n");
}

TEST(Blocks, FencedCode) {
  EXPECT_HTML("```\n<a>\n```", "<pre><code>&lt;a&gt;\n</code></pre>\n");
  EXPECT_HTML("~~~ ruby startline=3\nx\n~~~", "<pre><code class=\"language-ruby\">x\n</code></pre>\n");
  EXPECT_HTML("```\nopen", "<pre><code>open\n</code></pre>\n");
  EXPECT_HTML("````\n```\n````", "<pre><code>```\n</code></pre>\n");
  EXPECT_HTML("``` a`b\nx", "<p>``` a`b\nx</p>\n");
  EXPECT_HTML(" ```\n a\n  b\n ```", "<pre><code>a\n b\n</code></pre>\n");
  EXPECT_HTML("```language-x\n```", "<pre><code class=\"language-x\"></code></pre>\n");
  EXPECT_HTML("```&#92;*a\n```", "<pre><code class=\"language-*a\"></code></pre>\n");
}

TEST(Blocks, BlockQuotes) {
  EXPECT_HTML("> a\n> b", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n");
  EXPECT_HTML("> a\nlazy", "<blockquote>\n<p>a\nlazy</p>\n</blockquote>\n");
  EXPECT_HTML(">a\n\n>b", "<blockquote>\n<p>a</p>\n</blockquote>\n<blockquote>\n<p>b</p>\n</blockquote>\n");
  EXPECT_HTML("> > a", "<blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n</blockquote>\n");
  EXPECT_HTML(">", "<blockquote>\n</blockquote>\n");
  EXPECT_HTML("> # h\n> text", "<blockquote>\n<h1>h</h1>\n<p>text</p>\n</blockquote>\n");
}

TEST(Blocks, BulletLists) {
  EXPECT_HTML("- a\n- b", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
  EXPECT_HTML("- a\n+ b", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n");
  EXPECT_HTML("-", "<ul>\n<li></li>\n</ul>\n");
  EXPECT_HTML("-a", "<p>-a</p>\n");
  EXPECT_HTML("- a\n  - b", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n");
}

TEST(Blocks, OrderedLists) {
  EXPECT_HTML("1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n");
  EXPECT_HTML("3) a", "<ol start=\"3\">\n<li>a</li>\n</ol>\n");
  EXPECT_HTML("003. a", "<ol start=\"3\">\n<li>a</li>\n</ol>\n");
  EXPECT_HTML("0. a", "<ol start=\"0\">\n<li>a</li>\n</ol>\n");
  EXPECT_HTML("1. a\n2) b", "<ol>\n<li>a</li>\n</ol>\n<ol start=\"2\">\n<li>b</li>\n</ol>\n");
  EXPECT_HTML("1234567890. a", "<p>1234567890. a</p>\n");
}

TEST(Blocks, OnlyOneInterruptsAParagraph) {
  EXPECT_HTML("a\n2. b", "<p>a\n2. b</p>\n");
  EXPECT_HTML("a\n1. b", "<p>a</p>\n<ol>\n<li>b</li>\n</ol>\n");
  EXPECT_HTML("a\n-\nb", "<h2>a</h2>\n<p>b</p>\n");
  EXPECT_HTML("a\n* \nb", "<p>a\n*\nb</p>\n");
}

TEST(Blocks, TightAndLoose) {
  EXPECT_HTML("- a\n- b\n\n- c", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
  EXPECT_HTML("- a\n\n  b\n- c", "<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
  EXPECT_HTML("- a\n  - b\n\n  - c\n- d",
              "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n");
  // Blank lines inside a fenced block do not loosen the list.
  EXPECT_HTML("- ```\n  a\n\n  b\n  ```\n- c",
              "<ul>\n<li>\n<pre><code>a\n\nb\n</code></pre>\n</li>\n<li>c</li>\n</ul>\n");
  // A blank line after a thematic break is attributed to the break.
  EXPECT_HTML("- a\n  ***\n\n- b", "<ul>\n<li>a\n<hr />\n</li>\n<li>b</li>\n</ul>\n");
}

TEST(Blocks, ListItemIndentation) {
  EXPECT_HTML("-    a\n\n     b", "<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n");
  EXPECT_HTML("-     code", "<ul>\n<li>\n<pre><code>code\n</code></pre>\n</li>\n</ul>\n");
  EXPECT_HTML("- a\n b", "<ul>\n<li>a\nb</li>\n</ul>\n");
  EXPECT_HTML("1. a\n\n  b", "<ol>\n<li>a</li>\n</ol>\n<p>b</p>\n");
}

TEST(Blocks, Tabs) {
  EXPECT_HTML("- foo\n\n\t\tbar", "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n");
  EXPECT_HTML(">\t\tfoo", "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n");
  EXPECT_HTML("a\t\tb", "<p>a\t\tb</p>\n");
}

TEST(Blocks, LazyContinuation) {
  EXPECT_HTML("> a\n    b", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n");
  EXPECT_HTML("- a\nb", "<ul>\n<li>a\nb</li>\n</ul>\n");
  EXPECT_HTML("> - a\nb", "<blockquote>\n<ul>\n<li>a\nb</li>\n</ul>\n</blockquote>\n");
  EXPECT_HTML("> a\n\nb", "<blockquote>\n<p>a</p>\n</blockquote>\n<p>b</p>\n");
}

TEST(Blocks, ListsInsideQuotesAndBack) {
  EXPECT_HTML("> 1. > a\n> 2. b",
              "<blockquote>\n<ol>\n<li>\n<blockquote>\n<p>a</p>\n</blockquote>\n</li>\n<li>b</li>\n</ol>\n</blockquote>\n");
}

TEST(Blocks, NestingDeeperThanAHundredLevels) {
  std::string quotes;
  for (int i = 0; i < 300; ++i) quotes += "> ";
  const std::string html = commonmark::to_html(quotes + "deep");
  EXPECT_NE(html.find("<p>deep</p>"), std::string::npos);
  std::size_t opens = 0;
  for (std::size_t p = html.find("<blockquote>"); p != std::string::npos; p = html.find("<blockquote>", p + 1)) ++opens;
  EXPECT_EQ(opens, 300u);

  std::string list;
  for (int i = 0; i < 300; ++i) list += std::string(static_cast<std::size_t>(i) * 2, ' ') + "- x\n";
  const std::string lhtml = commonmark::to_html(list);
  std::size_t items = 0;
  for (std::size_t p = lhtml.find("<li>"); p != std::string::npos; p = lhtml.find("<li>", p + 1)) ++items;
  EXPECT_EQ(items, 300u);
}
