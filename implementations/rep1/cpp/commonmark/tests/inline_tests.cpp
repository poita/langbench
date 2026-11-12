// Inline structure: escapes, entities, code spans, emphasis, breaks.
#include "test_helpers.h"

TEST(Inlines, PlainTextIsEscaped) {
  EXPECT_HTML("a < b & c > d \"q\" 'x'", "<p>a &lt; b &amp; c &gt; d &quot;q&quot; 'x'</p>\n");
  EXPECT_HTML("caf\xC3\xA9 \xF0\x9F\x98\x80", "<p>caf\xC3\xA9 \xF0\x9F\x98\x80</p>\n");
}

TEST(Inlines, BackslashEscapes) {
  EXPECT_HTML("\\*not em\\*", "<p>*not em*</p>\n");
  EXPECT_HTML("\\a \\\\ \\", "<p>\\a \\ \\</p>\n");
  EXPECT_HTML("a\\\nb", "<p>a<br />\nb</p>\n");
  EXPECT_HTML("\\<b>", "<p>&lt;b&gt;</p>\n");
}

TEST(Inlines, Entities) {
  EXPECT_HTML("&amp; &lt; &gt; &quot;", "<p>&amp; &lt; &gt; &quot;</p>\n");
  EXPECT_HTML("&#65;&#x42;&#X43;", "<p>ABC</p>\n");
  EXPECT_HTML("&#0;", "<p>\xEF\xBF\xBD</p>\n");
  EXPECT_HTML("&#xD800;&#x110000;", "<p>\xEF\xBF\xBD\xEF\xBF\xBD</p>\n");
  EXPECT_HTML("&#12345678; &#; &#x; &foo; &amp", "<p>&amp;#12345678; &amp;#; &amp;#x; &amp;foo; &amp;amp</p>\n");
  EXPECT_HTML("&#128512;", "<p>\xF0\x9F\x98\x80</p>\n");
  EXPECT_HTML("&AMP;", "<p>&amp;AMP;</p>\n");
}

TEST(Inlines, CodeSpans) {
  EXPECT_HTML("`a`", "<p><code>a</code></p>\n");
  EXPECT_HTML("`` a`b ``", "<p><code>a`b</code></p>\n");
  EXPECT_HTML("` a `", "<p><code>a</code></p>\n");
  EXPECT_HTML("`  `", "<p><code>  </code></p>\n");
  EXPECT_HTML("`a\nb`", "<p><code>a b</code></p>\n");
  EXPECT_HTML("`a", "<p>`a</p>\n");
  EXPECT_HTML("``a`", "<p>``a`</p>\n");
  EXPECT_HTML("`<b>&amp;`", "<p><code>&lt;b&gt;&amp;amp;</code></p>\n");
  EXPECT_HTML("`\\`", "<p><code>\\</code></p>\n");
}

TEST(Inlines, CodeSpanMemoMatchesCmark) {
  // The failed search for ``` records the last run of each length; the later
  // successful `` search overwrites the entry for single backticks with an
  // earlier position, so the lone ` at the end is not paired. cmark behaves
  // this way and the expected outputs depend on it.
  EXPECT_HTML("``` a `` b ` c `` d ` e ` f", "<p>``` a <code>b ` c</code> d ` e ` f</p>\n");
}

TEST(Inlines, Emphasis) {
  EXPECT_HTML("*a*", "<p><em>a</em></p>\n");
  EXPECT_HTML("_a_", "<p><em>a</em></p>\n");
  EXPECT_HTML("**a**", "<p><strong>a</strong></p>\n");
  EXPECT_HTML("***a***", "<p><em><strong>a</strong></em></p>\n");
  EXPECT_HTML("* a *", "<ul>\n<li>a *</li>\n</ul>\n");
  EXPECT_HTML("a * b *", "<p>a * b *</p>\n");
  EXPECT_HTML("foo*bar*", "<p>foo<em>bar</em></p>\n");
  EXPECT_HTML("foo_bar_", "<p>foo_bar_</p>\n");
  EXPECT_HTML("_a_b_", "<p><em>a_b</em></p>\n");
  EXPECT_HTML("**a *b* c**", "<p><strong>a <em>b</em> c</strong></p>\n");
}

TEST(Inlines, RuleOfThree) {
  EXPECT_HTML("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n");
  EXPECT_HTML("*foo**bar*", "<p><em>foo**bar</em></p>\n");
  EXPECT_HTML("foo***bar***baz", "<p>foo<em><strong>bar</strong></em>baz</p>\n");
  EXPECT_HTML("**foo*", "<p>*<em>foo</em></p>\n");
}

TEST(Inlines, FlankingWithPunctuation) {
  EXPECT_HTML("*(a)*", "<p><em>(a)</em></p>\n");
  EXPECT_HTML("a*\"b\"*", "<p>a*&quot;b&quot;*</p>\n");
  EXPECT_HTML("*\"b\"* a", "<p><em>&quot;b&quot;</em> a</p>\n");
  EXPECT_HTML("_(a)_b", "<p>_(a)_b</p>\n");
}

TEST(Inlines, DeepEmphasisNesting) {
  std::string md;
  const int depth = 5000;
  for (int i = 0; i < depth; ++i) md += "*a ";
  for (int i = 0; i < depth; ++i) md += "b* ";
  const std::string html = commonmark::to_html(md);
  std::size_t ems = 0;
  for (std::size_t p = html.find("<em>"); p != std::string::npos; p = html.find("<em>", p + 1)) ++ems;
  EXPECT_EQ(ems, static_cast<std::size_t>(depth));
}

TEST(Inlines, LineBreaks) {
  EXPECT_HTML("a  \nb", "<p>a<br />\nb</p>\n");
  EXPECT_HTML("a \nb", "<p>a\nb</p>\n");
  EXPECT_HTML("a\nb", "<p>a\nb</p>\n");
  EXPECT_HTML("a\n   b", "<p>a\nb</p>\n");
  EXPECT_HTML("a   \nb", "<p>a<br />\nb</p>\n");
  EXPECT_HTML("a  ", "<p>a</p>\n");
  EXPECT_HTML("a\\", "<p>a\\</p>\n");
}

TEST(Inlines, Autolinks) {
  EXPECT_HTML("<http://a.b/c?d=1&e=2>", "<p><a href=\"http://a.b/c?d=1&amp;e=2\">http://a.b/c?d=1&amp;e=2</a></p>\n");
  EXPECT_HTML("<foo@bar.example.com>", "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n");
  EXPECT_HTML("<ab:c>", "<p><a href=\"ab:c\">ab:c</a></p>\n");
  EXPECT_HTML("<a:b>", "<p>&lt;a:b&gt;</p>\n");  // schemes need 2-32 characters
  EXPECT_HTML("<a b>", "<p>&lt;a b&gt;</p>\n");
  EXPECT_HTML("<x:y z>", "<p>&lt;x:y z&gt;</p>\n");
  EXPECT_HTML("<>", "<p>&lt;&gt;</p>\n");
  EXPECT_HTML("<foo@-bar.com>", "<p>&lt;foo@-bar.com&gt;</p>\n");
  EXPECT_HTML("<http://a\\*b>", "<p><a href=\"http://a%5C*b\">http://a\\*b</a></p>\n");
  EXPECT_HTML("<javascript:alert(1)>", "<p><a href=\"\">javascript:alert(1)</a></p>\n");
}
