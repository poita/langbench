// Inline links and images.
#include "test_helpers.h"

TEST(Links, Basic) {
  EXPECT_HTML("[a](/u)", "<p><a href=\"/u\">a</a></p>\n");
  EXPECT_HTML("[a](/u \"t\")", "<p><a href=\"/u\" title=\"t\">a</a></p>\n");
  EXPECT_HTML("[a](/u 't')", "<p><a href=\"/u\" title=\"t\">a</a></p>\n");
  EXPECT_HTML("[a](/u (t))", "<p><a href=\"/u\" title=\"t\">a</a></p>\n");
  EXPECT_HTML("[a]()", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](<>)", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](/u \"\")", "<p><a href=\"/u\" title=\"\">a</a></p>\n");
  EXPECT_HTML("[a]( /u )", "<p><a href=\"/u\">a</a></p>\n");
  EXPECT_HTML("[a](\n/u\n\"t\"\n)", "<p><a href=\"/u\" title=\"t\">a</a></p>\n");
}

TEST(Links, ReferenceStyleIsPlainText) {
  EXPECT_HTML("[a]", "<p>[a]</p>\n");
  EXPECT_HTML("[a][b]", "<p>[a][b]</p>\n");
  EXPECT_HTML("[a][]", "<p>[a][]</p>\n");
}

TEST(Links, Destinations) {
  EXPECT_HTML("[a](</my uri>)", "<p><a href=\"/my%20uri\">a</a></p>\n");
  EXPECT_HTML("[a](/my uri)", "<p>[a](/my uri)</p>\n");
  EXPECT_HTML("[a](<a>b)", "<p>[a](&lt;a&gt;b)</p>\n");
  EXPECT_HTML("[a](/u(v)w)", "<p><a href=\"/u(v)w\">a</a></p>\n");
  EXPECT_HTML("[a](/u(v)", "<p>[a](/u(v)</p>\n");
  EXPECT_HTML("[a](/u\\)v)", "<p><a href=\"/u)v\">a</a></p>\n");
  EXPECT_HTML("[a](/\xC3\xBC)", "<p><a href=\"/%C3%BC\">a</a></p>\n");
  EXPECT_HTML("[a](/a%20b)", "<p><a href=\"/a%20b\">a</a></p>\n");
  EXPECT_HTML("[a](/a&amp;b'c)", "<p><a href=\"/a&amp;b&#x27;c\">a</a></p>\n");
  EXPECT_HTML("[a](/&#92;*)", "<p><a href=\"/*\">a</a></p>\n");
  EXPECT_HTML("[a](\\&amp;)", "<p><a href=\"&amp;\">a</a></p>\n");
}

TEST(Links, ParenthesesNestingLimit) {
  std::string ok = "[a](" + std::string(32, '(') + std::string(32, ')') + ")";
  EXPECT_NE(commonmark::to_html(ok).find("<a href="), std::string::npos);
  std::string bad = "[a](" + std::string(33, '(') + std::string(33, ')') + ")";
  EXPECT_EQ(commonmark::to_html(bad).find("<a href="), std::string::npos);
}

TEST(Links, Titles) {
  EXPECT_HTML("[a](/u \"t\\\"x\")", "<p><a href=\"/u\" title=\"t&quot;x\">a</a></p>\n");
  EXPECT_HTML("[a](/u \"a\nb\")", "<p><a href=\"/u\" title=\"a\nb\">a</a></p>\n");
  EXPECT_HTML("[a](/u \"&amp;&#35;\")", "<p><a href=\"/u\" title=\"&amp;#\">a</a></p>\n");
  EXPECT_HTML("[a](/u(\"t\"))", "<p><a href=\"/u(%22t%22)\">a</a></p>\n");
  EXPECT_HTML("[a](/u\"t\")", "<p><a href=\"/u%22t%22\">a</a></p>\n");
  EXPECT_HTML("[a](<b>\"t\")", "<p>[a](&lt;b&gt;&quot;t&quot;)</p>\n");
  EXPECT_HTML("[a](/u \"t\" x)", "<p>[a](/u &quot;t&quot; x)</p>\n");
}

TEST(Links, UnsafeSchemes) {
  EXPECT_HTML("[a](javascript:alert(1))", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](JavaScript:x)", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](vbscript:x)", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](file:///etc/passwd)", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("[a](data:text/html,x)", "<p><a href=\"\">a</a></p>\n");
  EXPECT_HTML("![a](data:image/png;base64,AAA)", "<p><img src=\"data:image/png;base64,AAA\" alt=\"a\" /></p>\n");
  EXPECT_HTML("[a](http://x)", "<p><a href=\"http://x\">a</a></p>\n");
}

TEST(Links, Inlines) {
  EXPECT_HTML("[*a* `b`](/u)", "<p><a href=\"/u\"><em>a</em> <code>b</code></a></p>\n");
  EXPECT_HTML("*[a*](/u)", "<p>*<a href=\"/u\">a*</a></p>\n");
  EXPECT_HTML("[a *b](/u)*", "<p><a href=\"/u\">a *b</a>*</p>\n");
  EXPECT_HTML("[a [b](/b)](/a)", "<p>[a <a href=\"/b\">b</a>](/a)</p>\n");
  EXPECT_HTML("[a]\\(/u)", "<p>[a](/u)</p>\n");
  EXPECT_HTML("[a`](/u)`", "<p>[a<code>](/u)</code></p>\n");
}

TEST(Links, LinkClosedFlagQuirk) {
  // The single "link closed" flag is what cmark does, even where it differs
  // from "deactivate all earlier openers".
  EXPECT_HTML("[x [a](/b) ![i](/j) y](/d)", "<p>[x <a href=\"/b\">a</a> <img src=\"/j\" alt=\"i\" /> y](/d)</p>\n");
  EXPECT_HTML("[x [a](/b) ![i [q] j](/k) y](/d)",
              "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n");
}

TEST(Images, Basic) {
  EXPECT_HTML("![a](/i.png)", "<p><img src=\"/i.png\" alt=\"a\" /></p>\n");
  EXPECT_HTML("![a](/i.png \"t\")", "<p><img src=\"/i.png\" alt=\"a\" title=\"t\" /></p>\n");
  EXPECT_HTML("![](/i)", "<p><img src=\"/i\" alt=\"\" /></p>\n");
  EXPECT_HTML("![a", "<p>![a</p>\n");
  EXPECT_HTML("!a", "<p>!a</p>\n");
  EXPECT_HTML("\\![a](/u)", "<p>!<a href=\"/u\">a</a></p>\n");
}

TEST(Images, AltTextIsPlain) {
  EXPECT_HTML("![a *b* `c` <d>](/i)", "<p><img src=\"/i\" alt=\"a b c &lt;d&gt;\" /></p>\n");
  EXPECT_HTML("![a\nb  \nc](/i)", "<p><img src=\"/i\" alt=\"a b c\" /></p>\n");
  EXPECT_HTML("![a [b](/b) ![c](/c)](/i)", "<p><img src=\"/i\" alt=\"a b c\" /></p>\n");
  EXPECT_HTML("![\"q\" &amp;](/i)", "<p><img src=\"/i\" alt=\"&quot;q&quot; &amp;\" /></p>\n");
}

TEST(Links, DeeplyNestedBrackets) {
  std::string md;
  const int depth = 5000;
  for (int i = 0; i < depth; ++i) md += "![";
  md += "x";
  for (int i = 0; i < depth; ++i) md += "](/i)";
  const std::string html = commonmark::to_html(md);
  EXPECT_NE(html.find("alt=\"x\""), std::string::npos);
}
