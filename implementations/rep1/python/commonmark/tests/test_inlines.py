import pytest

from cmarkpy import convert


def p(inner):
    return f"<p>{inner}</p>\n"


@pytest.mark.parametrize(
    "md, inner",
    [
        ("*a* **b** _c_ __d__", "<em>a</em> <strong>b</strong> <em>c</em> <strong>d</strong>"),
        ("*foo**bar**baz*", "<em>foo<strong>bar</strong>baz</em>"),
        ("_a_b_", "<em>a_b</em>"),
        ("**a *b* c**", "<strong>a <em>b</em> c</strong>"),
        ("a * b * c", "a * b * c"),
        ("***a***", "<em><strong>a</strong></em>"),
        ("`a` ``b ` c``", "<code>a</code> <code>b ` c</code>"),
        ("` a `", "<code>a</code>"),
        ("`  `", "<code>  </code>"),
        ("`foo\nbar`", "<code>foo bar</code>"),
        ("```a``", "```a``"),
        ("\\*lit\\* \\a", "*lit* \\a"),
        ("&amp; &lt; &gt; &quot; &#65; &#x42; &#0; &foo; &amp", "&amp; &lt; &gt; &quot; A B � &amp;foo; &amp;amp"),
        ("&#12345678;", "&amp;#12345678;"),
        ("a  \nb", "a<br />\nb"),
        ("a\\\nb", "a<br />\nb"),
        ("a \nb", "a\nb"),
        ("a\n   b", "a\nb"),
        ("<http://a.b/?x=1&y=2>", '<a href="http://a.b/?x=1&amp;y=2">http://a.b/?x=1&amp;y=2</a>'),
        ("<foo@bar.com>", '<a href="mailto:foo@bar.com">foo@bar.com</a>'),
        ("<not a link> a < b", "&lt;not a link&gt; a &lt; b"),
        ("[a](/u)", '<a href="/u">a</a>'),
        ("[a](/u 'T')", '<a href="/u" title="T">a</a>'),
        ('[a](</my uri> "t\\"x")', '<a href="/my%20uri" title="t&quot;x">a</a>'),
        ("[a]()", '<a href="">a</a>'),
        ("[a](<>)", '<a href="">a</a>'),
        ('[k](/x "")', '<a href="/x" title="">k</a>'),
        ("[a](/my uri)", "[a](/my uri)"),
        ("[a](b(c)d)", '<a href="b(c)d">a</a>'),
        ("[a](javascript:alert(1))", '<a href="">a</a>'),
        ("[a](data:image/png;base64,xx)", '<a href="data:image/png;base64,xx">a</a>'),
        ("[a](/ü\\&amp;)", '<a href="/%C3%BC&amp;">a</a>'),
        ("[a](/f'o)", '<a href="/f&#x27;o">a</a>'),
        ("[a] [b][c]", "[a] [b][c]"),
        ("[a [b](/b)](/a)", '[a <a href="/b">b</a>](/a)'),
        ("![alt *x* `y`](/i.png)", '<img src="/i.png" alt="alt x y" />'),
        ('![a](/u "t")', '<img src="/u" alt="a" title="t" />'),
        ("![a ![b](/b)](/a)", '<img src="/a" alt="a b" />'),
        ("[x [a](/b) ![i](/j) y](/d)", '[x <a href="/b">a</a> <img src="/j" alt="i" /> y](/d)'),
        (
            "[x [a](/b) ![i [q] j](/k) y](/d)",
            '<a href="/d">x <a href="/b">a</a> <img src="/k" alt="i [q] j" /> y</a>',
        ),
        ("*[a](/u)*", '<em><a href="/u">a</a></em>'),
        ("[*a*](/u)", '<a href="/u"><em>a</em></a>'),
    ],
)
def test_inlines(md, inner):
    assert convert(md) == p(inner)


def test_unmatched_backtick_runs_are_linear():
    md = " ".join("`" * (i % 50 + 1) for i in range(6000))
    assert convert(md).startswith("<p>")


def test_many_unmatched_brackets_is_fast():
    md = "[" * 5000 + "]" * 5000
    assert convert(md) == p(md)


def test_deep_emphasis_nesting():
    md = "*a " * 4000 + "b" + " a*" * 4000
    html = convert(md)
    assert html.count("<em>") == 4000


def test_deep_image_nesting():
    md = "![" * 3000 + "x" + "](/u)" * 3000
    html = convert(md)
    assert html.startswith('<p><img src="/u" alt="')
