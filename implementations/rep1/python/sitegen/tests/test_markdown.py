import pytest

from sitegen.markdown import to_html

# Every expected output below was checked against cmark 0.31.2.
CASES = [
    ("", ""),
    ("\n\n", ""),
    ("hello", "<p>hello</p>\n"),
    ("# Title #\n", "<h1>Title</h1>\n"),
    ("#\n", "<h1></h1>\n"),
    ("# foo#\n", "<h1>foo#</h1>\n"),
    ("####### seven\n", "<p>####### seven</p>\n"),
    ("Foo\n---\n", "<h2>Foo</h2>\n"),
    ("Foo\nbar\n===\n", "<h1>Foo\nbar</h1>\n"),
    ("***\n", "<hr />\n"),
    ("- - -\n", "<hr />\n"),
    ("    code <b>\n", "<pre><code>code &lt;b&gt;\n</code></pre>\n"),
    ("    a\n\n\n    b\n\n", "<pre><code>a\n\n\nb\n</code></pre>\n"),
    ("```py\nx = 1\n```\n", '<pre><code class="language-py">x = 1\n</code></pre>\n'),
    ("~~~ language-foo bar\nx\n", '<pre><code class="language-foo">x\n</code></pre>\n'),
    ("```\nunclosed\n", "<pre><code>unclosed\n</code></pre>\n"),
    ("> quote\nlazy\n", "<blockquote>\n<p>quote\nlazy</p>\n</blockquote>\n"),
    ("- a\n- b\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"),
    ("- a\n\n- b\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"),
    ("3. a\n4. b\n", '<ol start="3">\n<li>a</li>\n<li>b</li>\n</ol>\n'),
    ("1. a\n2. b\n", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n"),
    ("- a\n  - b\n", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n"),
    ("-\n", "<ul>\n<li></li>\n</ul>\n"),
    ("- a\n* b\n", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n"),
    ("*em* **strong** ***both***\n", "<p><em>em</em> <strong>strong</strong> <em><strong>both</strong></em></p>\n"),
    ("*foo**bar**baz*\n", "<p><em>foo<strong>bar</strong>baz</em></p>\n"),
    ("snake_case_word\n", "<p>snake_case_word</p>\n"),
    ("`code` and `` a`b ``\n", "<p><code>code</code> and <code>a`b</code></p>\n"),
    ("[a](/u \"t\") ![i](/p.png)\n", '<p><a href="/u" title="t">a</a> <img src="/p.png" alt="i" /></p>\n'),
    ("[a](</my uri>)\n", '<p><a href="/my%20uri">a</a></p>\n'),
    ("[a](b(c)d)\n", '<p><a href="b(c)d">a</a></p>\n'),
    ("[a](b c)\n", "<p>[a](b c)</p>\n"),
    ("[a]\n", "<p>[a]</p>\n"),
    ("![a *b* `c`](/x)\n", '<p><img src="/x" alt="a b c" /></p>\n'),
    ("<http://a.b/?x=1&y=2>\n", '<p><a href="http://a.b/?x=1&amp;y=2">http://a.b/?x=1&amp;y=2</a></p>\n'),
    ("<me@example.com>\n", '<p><a href="mailto:me@example.com">me@example.com</a></p>\n'),
    ("a  \nb\\\nc\nd\n", "<p>a<br />\nb<br />\nc\nd</p>\n"),
    ("\\*lit\\* &amp; &lt; &#65; &#x42; &#0; &foo; &#12345678;\n",
     "<p>*lit* &amp; &lt; A B � &amp;foo; &amp;#12345678;</p>\n"),
    ("[j](javascript:alert(1)) [k](/x \"\") [](<>)\n", '<p><a href="">j</a> <a href="/x" title="">k</a> <a href=""></a></p>\n'),
    ("[a](/é?q=a b&c='\"<>)\n", "<p>[a](/é?q=a b&amp;c='&quot;&lt;&gt;)</p>\n"),
    ("[a](</é?q=a b&c='>)\n", '<p><a href="/%C3%A9?q=a%20b&amp;c=&#x27;">a</a></p>\n'),
    ("x\n    lazy code?\n", "<p>x\nlazy code?</p>\n"),
    ("a\n\tb\n", "<p>a\nb</p>\n"),
    ("-\ta\n", "<ul>\n<li>a</li>\n</ul>\n"),
    ("text\n- item\n", "<p>text</p>\n<ul>\n<li>item</li>\n</ul>\n"),
    ("text\n2. not a list\n", "<p>text\n2. not a list</p>\n"),
]


@pytest.mark.parametrize("source, html", CASES)
def test_conversion(source, html):
    assert to_html(source) == html


def test_spec_example_with_everything():
    source = (
        "# Title #\n\n"
        "Some *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n"
        "- one\n- two\n  - nested\n\n"
        "1. a\n\n   b\n2. c\n\n"
        "> quote  \n> line\\\n\tlazy\n\n"
        "    code <b>\n"
    )
    assert to_html(source) == (
        "<h1>Title</h1>\n"
        '<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a '
        '<a href="/my%20uri" title="t&quot;x">link</a>.</p>\n'
        "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n"
        "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n"
        "<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n"
        "<pre><code>code &lt;b&gt;\n</code></pre>\n"
    )


def test_code_spans_use_runs_of_equal_length():
    source = "`a ``b `c`` d``` `e``\n"
    assert to_html(source) == "<p><code>a ``b </code>c<code> d``` `e</code></p>\n"
    assert to_html("``a` ``b` `c` ``\n") == "<p><code>a` </code>b<code> </code>c` ``</p>\n"


def test_deep_nesting_does_not_overflow_the_stack():
    assert to_html("> " * 300 + "deep\n").count("<blockquote>") == 300
    html = to_html("*a " * 3000 + "b" + "*" * 3000)
    assert html.count("<strong>") * 2 + html.count("<em>") == 3000
    html = to_html("[a " * 2000 + "x" + "](/u) " * 2000)
    assert html.startswith("<p>")


def test_large_inputs_are_fast():
    assert to_html("".join(f"{i + 1}. item `c{i}` [l](/{i})\n" for i in range(5000))).count("<li>") == 5000
    assert to_html("[" * 5000 + "]" * 5000) == "<p>" + "[" * 5000 + "]" * 5000 + "</p>\n"
    assert to_html("```\n" + "x\n" * 100000 + "```\n").count("x") == 100000
