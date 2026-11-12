// HTML rendering of whole documents, including the worked examples.
#include "test_helpers.h"

TEST(Render, WorkedExampleOne) {
  const std::string md =
      "# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n"
      "- one\n- two\n  - nested\n\n1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n";
  const std::string html =
      "<h1>Title</h1>\n"
      "<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a "
      "<a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>\n"
      "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n"
      "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n"
      "<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n"
      "<pre><code>code &lt;b&gt;\n</code></pre>\n";
  EXPECT_HTML(md, html);
}

TEST(Render, WorkedExampleTwo) {
  const std::string md =
      "*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n"
      "<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb\n";
  const std::string html =
      "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> "
      "<img src=\"/i.png\" alt=\"alt x y\" />\n"
      "<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB\xEF\xBF\xBD *lit* a<br />\nb</p>\n";
  EXPECT_HTML(md, html);
}

TEST(Render, WorkedExampleThree) {
  const std::string md =
      "- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n"
      "[j](javascript:alert(1)) [k](/x \"\") [](<>)\n";
  const std::string html =
      "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n</code></pre>\n</li>\n"
      "<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n<h2>Foo</h2>\n"
      "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n";
  EXPECT_HTML(md, html);
}

TEST(Render, UrlEncoding) {
  EXPECT_HTML("[a](/a\"b<c>d[e]f\\g^h`i{j|k}l)",
              "<p><a href=\"/a%22b%3Cc%3Ed%5Be%5Df%5Cg%5Eh%60i%7Bj%7Ck%7Dl\">a</a></p>\n");
  EXPECT_HTML("[a](/!#$%()*+,-./:;=?@_~)", "<p><a href=\"/!#$%()*+,-./:;=?@_~\">a</a></p>\n");
}

TEST(Render, CodeBlockClassUsesFirstWordOnly) {
  EXPECT_HTML("```a\"b c\n```", "<pre><code class=\"language-a&quot;b\"></code></pre>\n");
}

TEST(Render, TightListWithBlockChildren) {
  EXPECT_HTML("- a\n  > q\n- b", "<ul>\n<li>a\n<blockquote>\n<p>q</p>\n</blockquote>\n</li>\n<li>b</li>\n</ul>\n");
  EXPECT_HTML("- # h\n- b", "<ul>\n<li>\n<h1>h</h1>\n</li>\n<li>b</li>\n</ul>\n");
}

TEST(Render, EmptyItems) {
  EXPECT_HTML("-\n-\n", "<ul>\n<li></li>\n<li></li>\n</ul>\n");
  EXPECT_HTML("- a\n-\n- b", "<ul>\n<li>a</li>\n<li></li>\n<li>b</li>\n</ul>\n");
}

TEST(Render, OutputEndsWithNewline) {
  EXPECT_EQ(commonmark::to_html("a").back(), '\n');
  EXPECT_EQ(commonmark::to_html("    a").back(), '\n');
}
