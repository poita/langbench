/**
 * Unit tests: conformance with the CommonMark specification examples that fall
 * inside the supported subset, plus stress tests for nesting and
 * pathological inputs. This module contains tests only.
 */
module commonmark.conformance;

version (unittest):

import commonmark : toHtml;
import std.array : replicate;
import std.format : format;
import std.json : parseJSON;

/// Every example in tests/data/spec_examples.json must convert exactly.
unittest
{
    enum examples = import("spec_examples.json");
    foreach (ex; parseJSON(examples).array)
    {
        immutable md = ex["md"].str;
        immutable expected = ex["html"].str;
        immutable actual = toHtml(md);
        assert(actual == expected,
            format("spec example %d (%s) failed:\n%s\nexpected: %s\nactual:   %s",
                ex["n"].integer, ex["sec"].str, md, expected, actual));
    }
}

unittest // output of the worked examples in the problem statement
{
    assert(toHtml("*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)\n<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \\*lit\\* a\\\nb\n")
        == "<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> <img src=\"/i.png\" alt=\"alt x y\" />\n"
        ~ "<a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB\uFFFD *lit* a<br />\nb</p>\n");
    assert(toHtml("- a\n- ```py\n  x = \"<>\"\n  ```\n- c\n\n  d\n* e\n***\nFoo\n---\n[j](javascript:alert(1)) [k](/x \"\") [](<>)")
        == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<pre><code class=\"language-py\">x = &quot;&lt;&gt;&quot;\n</code></pre>\n</li>\n"
        ~ "<li>\n<p>c</p>\n<p>d</p>\n</li>\n</ul>\n<ul>\n<li>e</li>\n</ul>\n<hr />\n<h2>Foo</h2>\n"
        ~ "<p><a href=\"\">j</a> <a href=\"/x\" title=\"\">k</a> <a href=\"\"></a></p>\n");
}

unittest // link_closed behaviour matches cmark, not the specification text
{
    assert(toHtml("[x [a](/b) ![i [q] j](/k) y](/d)")
        == "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n");
    assert(toHtml("[x [a](/b) ![i](/j) y](/d)")
        == "<p>[x <a href=\"/b\">a</a> <img src=\"/j\" alt=\"i\" /> y](/d)</p>\n");
}

unittest // blank line after an empty item and thematic break tightness
{
    assert(toHtml("- a\n  ***\n\n- b\n") == "<ul>\n<li>a\n<hr />\n</li>\n<li>b</li>\n</ul>\n");
}

unittest // code span memo: an unmatched run makes later searches fail fast
{
    assert(toHtml("`a ``b` c``") == "<p><code>a ``b</code> c``</p>\n");
}

unittest // deep nesting must not overflow the stack
{
    enum depth = 300;
    auto quotes = toHtml("> ".replicate(depth) ~ "x\n");
    assert(quotes.length > depth * 2);
    auto lists = toHtml(() {
        string s;
        foreach (i; 0 .. depth)
            s ~= " ".replicate(i * 2) ~ "- ";
        return s ~ "x\n";
    }());
    assert(lists.length > depth * 2);

    auto emph = toHtml("*a ".replicate(5000) ~ "b" ~ " a*".replicate(5000));
    assert(emph.length > 5000);
    auto brackets = toHtml("[".replicate(5000) ~ "x" ~ "]".replicate(5000));
    assert(brackets.length > 10_000);
    auto images = toHtml("![a ".replicate(3000) ~ "x" ~ "](/u)".replicate(3000));
    assert(images.length > 3000);
}

unittest // pathological inputs run in reasonable time
{
    import std.datetime.stopwatch : StopWatch, AutoStart;

    auto sw = StopWatch(AutoStart.yes);
    toHtml("_a ".replicate(20_000));
    toHtml("**a ".replicate(20_000));
    toHtml("`a ``b ```c ".replicate(10_000));
    toHtml("[a](b ".replicate(20_000));
    toHtml("*a_ ".replicate(20_000) ~ "_a* ".replicate(20_000));
    assert(sw.peek.total!"seconds" < 10);
}
