/// Tests for the HTML escaping helpers and the public API.
module commonmark_tests.html_test;

import commonmark;

unittest
{
    Buffer b;
    escapeHtml(b, `a<b>&"c'`);
    assert(b.data == "a&lt;b&gt;&amp;&quot;c'");
}

unittest
{
    Buffer b;
    escapeHref(b, "/a b?x=1&y='z'#é");
    assert(b.data == "/a%20b?x=1&amp;y=&#x27;z&#x27;#%C3%A9");

    Buffer c;
    escapeHref(c, "JavaScript:alert(1)");
    assert(c.empty);

    Buffer d;
    escapeHref(d, "data:image/png;base64,AAAA");
    assert(d.data == "data:image/png;base64,AAAA");

    Buffer e;
    escapeHref(e, "data:text/html,x");
    assert(e.empty);

    Buffer f;
    escapeHref(f, "/100%25");
    assert(f.data == "/100%25");
}

unittest
{
    // The public API appends to an existing buffer.
    Buffer b;
    b.put("X");
    toHtml("*a*", b);
    assert(b.data == "X<p><em>a</em></p>\n");
    assert(toHtml("") == "");
    assert(toHtml("\n\n") == "");
}

unittest
{
    // Examples from the specification of this converter.
    assert(toHtml("*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n"
        ~ "<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb\n")
        == "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> "
        ~ "<img src=\"/i.png\" alt=\"alt x y\" />\n"
        ~ "<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB� *lit* a<br />\nb</p>\n");

    assert(toHtml("- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n"
        ~ "[j](javascript:alert(1)) [k](/x \"\") [](<>)\n")
        == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n"
        ~ "</code></pre>\n</li>\n<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n"
        ~ "<h2>Foo</h2>\n<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n");
}

unittest
{
    // Pathological inputs must stay fast and not crash.
    import std.array : replicate;

    assert(toHtml("[".replicate(5000) ~ "]".replicate(5000)).length > 0);
    assert(toHtml("*a ".replicate(20000)).length > 0);
    assert(toHtml("`a ``b ```c ".replicate(5000)).length > 0);
    assert(toHtml("> ".replicate(300) ~ "x\n").length > 0);
}
