import pytest

from cmarkpy import convert, parse
from cmarkpy import nodes


@pytest.mark.parametrize(
    "md, html",
    [
        ("", ""),
        ("\n", ""),
        ("   \n\n", ""),
        ("***\n---\n___", "<hr />\n<hr />\n<hr />\n"),
        ("# a #\n###### b\n####### c", "<h1>a</h1>\n<h6>b</h6>\n<p>####### c</p>\n"),
        ("# foo#\n# foo \\#", "<h1>foo#</h1>\n<h1>foo #</h1>\n"),
        ("### ###\n#", "<h3></h3>\n<h1></h1>\n"),
        ("Foo\nbar\n---", "<h2>Foo\nbar</h2>\n"),
        ("> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n"),
        ("    a\n\n\n    b\n", "<pre><code>a\n\n\nb\n</code></pre>\n"),
        ("    foo  \n", "<pre><code>foo  \n</code></pre>\n"),
        ("```py x\na < b\n```", '<pre><code class="language-py">a &lt; b\n</code></pre>\n'),
        ("```language-c\n```", '<pre><code class="language-c"></code></pre>\n'),
        ("~~~\nunclosed", "<pre><code>unclosed\n</code></pre>\n"),
        (" ```\n  a\n ```", "<pre><code> a\n</code></pre>\n"),
        ("> a\nb\n\n> c", "<blockquote>\n<p>a\nb</p>\n</blockquote>\n<blockquote>\n<p>c</p>\n</blockquote>\n"),
        ("- a\n- b", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"),
        ("- a\n\n- b", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n"),
        ("- a\n* b", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n"),
        ("3. a\n4. b", '<ol start="3">\n<li>a</li>\n<li>b</li>\n</ol>\n'),
        ("0. a", '<ol start="0">\n<li>a</li>\n</ol>\n'),
        ("a\n2. b", "<p>a\n2. b</p>\n"),
        ("a\n1. b", "<p>a</p>\n<ol>\n<li>b</li>\n</ol>\n"),
        ("-\n  foo", "<ul>\n<li>foo</li>\n</ul>\n"),
        ("- ", "<ul>\n<li></li>\n</ul>\n"),
        ("- a\n  - b\n", "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n"),
        ("- a\n---", "<ul>\n<li>a</li>\n</ul>\n<hr />\n"),
        ("- ```\n  x\n  ```\n\n  y", "<ul>\n<li>\n<pre><code>x\n</code></pre>\n<p>y</p>\n</li>\n</ul>\n"),
        ("1234567890. a", "<p>1234567890. a</p>\n"),
        ("\tfoo", "<pre><code>foo\n</code></pre>\n"),
        ("- foo\n\n\t\tbar", "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n"),
        (">\tfoo", "<blockquote>\n<p>foo</p>\n</blockquote>\n"),
    ],
)
def test_blocks(md, html):
    assert convert(md) == html


def test_tree_shape():
    doc = parse("# T\n\n- a\n- b\n")
    assert doc.type == nodes.DOCUMENT
    heading, lst = list(doc.children())
    assert heading.type == nodes.HEADING and heading.level == 1
    assert lst.type == nodes.LIST and lst.tight
    assert [i.type for i in lst.children()] == [nodes.ITEM, nodes.ITEM]


def test_last_line_without_newline_and_trailing_newline_equal():
    assert convert("a\n- b") == convert("a\n- b\n")


def test_deep_block_quotes():
    depth = 300
    html = convert(">" * depth + " x")
    assert html.count("<blockquote>") == depth
    assert "<p>x</p>" in html


def test_deep_lists():
    md = "".join(" " * (2 * i) + "- x\n" for i in range(150))
    html = convert(md)
    assert html.count("<ul>") == 150
