/// Tests for commonmark.inlines through the public conversion API.
module commonmark_tests.inlines_test;

import commonmark;

private string p(string inner)
{
    return "<p>" ~ inner ~ "</p>\n";
}

unittest // emphasis
{
    assert(toHtml("*foo bar*") == p("<em>foo bar</em>"));
    assert(toHtml("a * foo bar*") == p("a * foo bar*"));
    assert(toHtml("foo*bar*") == p("foo<em>bar</em>"));
    assert(toHtml("_foo_bar_") == p("<em>foo_bar</em>"));
    assert(toHtml("**foo bar**") == p("<strong>foo bar</strong>"));
    assert(toHtml("***strong emph***") == p("<em><strong>strong emph</strong></em>"));
    assert(toHtml("*foo**bar**baz*") == p("<em>foo<strong>bar</strong>baz</em>"));
    assert(toHtml("*foo**bar*") == p("<em>foo**bar</em>"));
}

unittest // code spans
{
    assert(toHtml("`foo`") == p("<code>foo</code>"));
    assert(toHtml("`` foo ` bar ``") == p("<code>foo ` bar</code>"));
    assert(toHtml("` `` `") == p("<code>``</code>"));
    assert(toHtml("`foo") == p("`foo"));
    assert(toHtml("``foo`") == p("``foo`"));
    assert(toHtml("`a\nb`") == p("<code>a b</code>"));
    assert(toHtml("`<b>&`") == p("<code>&lt;b&gt;&amp;</code>"));
}

unittest // escapes, entities, breaks
{
    assert(toHtml(`\*not emph\*`) == p("*not emph*"));
    assert(toHtml(`\a`) == p(`\a`));
    assert(toHtml("&amp; &#65; &#x42; &#0;") == p("&amp; A B �"));
    assert(toHtml("&copy; &foo;") == p("&amp;copy; &amp;foo;"));
    assert(toHtml("a  \nb") == p("a<br />\nb"));
    assert(toHtml("a\\\nb") == p("a<br />\nb"));
    assert(toHtml("a\nb") == p("a\nb"));
    assert(toHtml("a \nb") == p("a\nb"));
}

unittest // links and images
{
    assert(toHtml("[a](/u)") == p(`<a href="/u">a</a>`));
    assert(toHtml(`[a](/u "t")`) == p(`<a href="/u" title="t">a</a>`));
    assert(toHtml(`[a](/u 'a"b')`) == p(`<a href="/u" title="a&quot;b">a</a>`));
    assert(toHtml("[a](<b c>)") == p(`<a href="b%20c">a</a>`));
    assert(toHtml("[a]()") == p(`<a href="">a</a>`));
    assert(toHtml("[a](/my uri)") == p("[a](/my uri)"));
    assert(toHtml("[a]") == p("[a]"));
    assert(toHtml("[*a*](/u)") == p(`<a href="/u"><em>a</em></a>`));
    assert(toHtml("![a *b*](/i.png)") == p(`<img src="/i.png" alt="a b" />`));
    assert(toHtml("![a](/i.png 'T')") == p(`<img src="/i.png" alt="a" title="T" />`));
    assert(toHtml("[a [b](/c) d](/e)") == p(`[a <a href="/c">b</a> d](/e)`));
    assert(toHtml("![a ![b](/c) d](/e)") == p(`<img src="/e" alt="a b d" />`));
    assert(toHtml("[x](javascript:alert(1))") == p(`<a href="">x</a>`));
    assert(toHtml("[x](/a&amp;b\\*)") == p(`<a href="/a&amp;b*">x</a>`));
}

unittest // autolinks
{
    assert(toHtml("<http://a.b/?x=1&y=2>") == p(`<a href="http://a.b/?x=1&amp;y=2">http://a.b/?x=1&amp;y=2</a>`));
    assert(toHtml("<foo@bar.com>") == p(`<a href="mailto:foo@bar.com">foo@bar.com</a>`));
    assert(toHtml("<a b>") == p("&lt;a b&gt;"));
    assert(toHtml("a < b > c") == p("a &lt; b &gt; c"));
}
