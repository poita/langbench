/// Unit tests for the Markdown converter.
module tests.markdown_test;

import sitegen.markdown;

private void check(string md, string html, string file = __FILE__, size_t line = __LINE__)
{
    auto got = markdownToHtml(md);
    assert(got == html, "markdown: " ~ md ~ "\nexpected: " ~ html ~ "\n     got: " ~ got);
}

unittest // empty and blank input
{
    check("", "");
    check("\n\n  \n", "");
}

unittest // blocks
{
    check("# Title #\n", "<h1>Title</h1>\n");
    check("###### six\n####### seven\n", "<h6>six</h6>\n<p>####### seven</p>\n");
    check("#5 bolt\n", "<p>#5 bolt</p>\n");
    check("# foo#\n", "<h1>foo#</h1>\n");
    check("### ###\n", "<h3></h3>\n");
    check("Foo\nbar\n---\n", "<h2>Foo\nbar</h2>\n");
    check("Foo\n===\n", "<h1>Foo</h1>\n");
    check("* * *\n- - -\n___\n", "<hr />\n<hr />\n<hr />\n");
    check("    code <b>\n\n    more\n\ntext", "<pre><code>code &lt;b&gt;\n\nmore\n</code></pre>\n<p>text</p>\n");
    check("```ruby x\nfoo\n\nbar\n```\n", "<pre><code class=\"language-ruby\">foo\n\nbar\n</code></pre>\n");
    check("~~~\nunclosed", "<pre><code>unclosed\n</code></pre>\n");
    check("```language-c\nx\n```", "<pre><code class=\"language-c\">x\n</code></pre>\n");
    check("   ```\n   a\n    b\n   ```\n", "<pre><code>a\n b\n</code></pre>\n");
    check("> a\nb\n> c\n", "<blockquote>\n<p>a\nb\nc</p>\n</blockquote>\n");
    check(">\tfoo\n", "<blockquote>\n<p>foo</p>\n</blockquote>\n");
    check("> foo\n---\n", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n");
}

unittest // lists
{
    check("- one\n- two\n  - nested\n", "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n");
    check("- a\n- b\n\n- c\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
    check("1. a\n\n   b\n2. c\n", "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n");
    check("2. x\n", "<ol start=\"2\">\n<li>x</li>\n</ol>\n");
    check("1) a\n\n- x\n+ y\n", "<ol>\n<li>a</li>\n</ol>\n<ul>\n<li>x</li>\n</ul>\n<ul>\n<li>y</li>\n</ul>\n");
    check("-\tfoo\n", "<ul>\n<li>foo</li>\n</ul>\n");
    check("- a\n  - b\n\n    c\n- d\n", "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n");
    check("- a\n-\n  b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
    check("* a\n*\n\n* c\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li></li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
    // a numbered line cannot interrupt a paragraph unless it starts at 1
    check("para\n2. x\n", "<p>para\n2. x</p>\n");
    check("para\n1. x\n", "<p>para</p>\n<ol>\n<li>x</li>\n</ol>\n");
}

unittest // inlines
{
    check("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n");
    check("_a_b_ **a *b* c**", "<p><em>a_b</em> <strong>a <em>b</em> c</strong></p>\n");
    check("`` a ` b ``", "<p><code>a ` b</code></p>\n");
    check("`unclosed", "<p>`unclosed</p>\n");
    check("a  \nb\\\nc\nd", "<p>a<br />\nb<br />\nc\nd</p>\n");
    check("\\*lit\\* &amp; &#65;&#x42;&#0; &copy;", "<p>*lit* &amp; AB\uFFFD &amp;copy;</p>\n");
    check("<http://a.b/?x=1&y=2> <me@example.com> <not a link>",
            "<p><a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> "
            ~ "<a href=\"mailto:me@example.com\">me@example.com</a> &lt;not a link&gt;</p>\n");
}

unittest // links and images
{
    check("[link](</my uri> \"t\\\"x\")", "<p><a href=\"/my%20uri\" title=\"t&quot;x\">link</a></p>\n");
    check("![alt *x* `y`](/i.png)", "<p><img src=\"/i.png\" alt=\"alt x y\" /></p>\n");
    check("[j](javascript:alert(1)) [k](/x \"\") [](<>)",
            "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n");
    check("[a](b(c)d) [e](f g)", "<p><a href=\"b(c)d\">a</a> [e](f g)</p>\n");
    check("[a] [b][c] [d][]", "<p>[a] [b][c] [d][]</p>\n");
    check("[x [a](/b) y](/d)", "<p>[x <a href=\"/b\">a</a> y](/d)</p>\n");
    check("[a](/u?x=1&y='2')", "<p><a href=\"/u?x=1&amp;y=&#x27;2&#x27;\">a</a></p>\n");
}

unittest // worked example from the specification
{
    check("# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n"
            ~ "- one\n- two\n  - nested\n\n1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n",
            "<h1>Title</h1>\n<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a "
            ~ "<a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>\n<ul>\n<li>one</li>\n<li>two\n<ul>\n"
            ~ "<li>nested</li>\n</ul>\n</li>\n</ul>\n<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n"
            ~ "</li>\n</ol>\n<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n"
            ~ "<pre><code>code &lt;b&gt;\n</code></pre>\n");
}

unittest // pathological inputs stay fast and do not crash
{
    import std.array : replicate;

    assert(markdownToHtml("[".replicate(5000) ~ "]".replicate(5000)).length > 0);
    assert(markdownToHtml("*a ".replicate(3000) ~ "b" ~ " c*".replicate(3000)).length > 0);
    assert(markdownToHtml("> ".replicate(200) ~ "x").length > 0);
}
