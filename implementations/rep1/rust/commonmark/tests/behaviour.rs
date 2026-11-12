//! Targeted tests of the behaviours SPEC.md calls out, including the places
//! where `cmark` differs from the CommonMark specification text.

use commonmark::{to_html, Document, NodeKind};

fn check(md: &str, html: &str) {
    assert_eq!(to_html(md), html, "markdown: {md:?}");
}

#[test]
fn blocks() {
    check("", "");
    check("# foo #\n", "<h1>foo</h1>\n");
    check("### ###\n", "<h3></h3>\n");
    check("# foo#\n", "<h1>foo#</h1>\n");
    check("Foo\nbar\n---\n", "<h2>Foo\nbar</h2>\n");
    check("> foo\n---\n", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n");
    check("- foo\n---\n", "<ul>\n<li>foo</li>\n</ul>\n<hr />\n");
    check("    foo  \n\n\n", "<pre><code>foo  \n</code></pre>\n");
    check("```\nunclosed", "<pre><code>unclosed\n</code></pre>\n");
    check("```\\*foo &#92;* bar\n```\n", "<pre><code class=\"language-*foo\"></code></pre>\n");
    check("``` language-x\n```\n", "<pre><code class=\"language-x\"></code></pre>\n");
}

#[test]
fn lists() {
    check("- a\n- b\n\n- c\n", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
    check("3. a\n", "<ol start=\"3\">\n<li>a</li>\n</ol>\n");
    check("0. a\n", "<ol start=\"0\">\n<li>a</li>\n</ol>\n");
    check("-\n", "<ul>\n<li></li>\n</ul>\n");
    check("a\n2. b\n", "<p>a\n2. b</p>\n");
    check("a\n1. b\n", "<p>a</p>\n<ol>\n<li>b</li>\n</ol>\n");
    check("- a\n* b\n", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n");
    // A blank line after a thematic break keeps the list tight.
    check("- a\n  ***\n\n- b\n", "<ul>\n<li>a\n<hr />\n</li>\n<li>b</li>\n</ul>\n");
}

#[test]
fn tabs() {
    check("\tfoo\tbaz\t\tbim\n", "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n");
    check("- foo\n\n\t\tbar\n", "<ul>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n");
    check(">\t\tfoo\n", "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n");
}

#[test]
fn inlines() {
    check("*foo**bar**baz*\n", "<p><em>foo<strong>bar</strong>baz</em></p>\n");
    check("_a_b_\n", "<p><em>a_b</em></p>\n");
    check("a  \nb\\\nc\nd\n", "<p>a<br />\nb<br />\nc\nd</p>\n");
    check("`` a ` b ``\n", "<p><code>a ` b</code></p>\n");
    check("`  `\n", "<p><code>  </code></p>\n");
    check("&amp;copy; &#65;&#x42;&#0; &#12345678;\n", "<p>&amp;copy; AB\u{FFFD} &amp;#12345678;</p>\n");
    check("\\*lit\\* \\a\n", "<p>*lit* \\a</p>\n");
}

#[test]
fn code_spans_without_closer() {
    // No closing run of the right length: the opening run is literal text, and
    // the later (shorter) runs still pair up correctly.
    check("``` ` `` x\n", "<p>``` ` `` x</p>\n");
    check("`a``b` ``\n", "<p><code>a``b</code> ``</p>\n");
}

#[test]
fn links_and_images() {
    check("[a](/u \"t\\\"x\")\n", "<p><a href=\"/u\" title=\"t&quot;x\">a</a></p>\n");
    check("[a](</my uri>)\n", "<p><a href=\"/my%20uri\">a</a></p>\n");
    check("[a](/my uri)\n", "<p>[a](/my uri)</p>\n");
    check("[a]()\n", "<p><a href=\"\">a</a></p>\n");
    check("[j](javascript:alert(1))\n", "<p><a href=\"\">j</a></p>\n");
    check("[k](/x \"\")\n", "<p><a href=\"/x\" title=\"\">k</a></p>\n");
    check("![alt *x* `y`](/i.png)\n", "<p><img src=\"/i.png\" alt=\"alt x y\" /></p>\n");
    check("[x [a](/b) y](/d)\n", "<p>[x <a href=\"/b\">a</a> y](/d)</p>\n");
    check(
        "[x [a](/b) ![i [q] j](/k) y](/d)\n",
        "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n",
    );
    check("[x [a](/b) ![i](/j) y](/d)\n", "<p>[x <a href=\"/b\">a</a> <img src=\"/j\" alt=\"i\" /> y](/d)</p>\n");
    check("[a](/\u{e9}'&)\n", "<p><a href=\"/%C3%A9&#x27;&amp;\">a</a></p>\n");
    check("[a][b] [c]\n", "<p>[a][b] [c]</p>\n");
}

#[test]
fn autolinks() {
    check("<http://a.b/?x=1&amp;y=2>\n", "<p><a href=\"http://a.b/?x=1&amp;y=2\">http://a.b/?x=1&amp;y=2</a></p>\n");
    check("<foo@bar.com>\n", "<p><a href=\"mailto:foo@bar.com\">foo@bar.com</a></p>\n");
    check("< http://a.b>\n", "<p>&lt; http://a.b&gt;</p>\n");
}

#[test]
fn worked_example_from_spec() {
    let md = "# Title #\n\nSome *emphasis*, **strong**, `code` and a [link](</my uri> \"t\\\"x\").\n\n- one\n- two\n  - nested\n\n1. a\n\n   b\n2. c\n\n> quote  \n> line\\\n\tlazy\n\n    code <b>\n";
    let expected = "<h1>Title</h1>\n<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href=\"/my%20uri\" title=\"t&quot;x\">link</a>.</p>\n<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ol>\n<blockquote>\n<p>quote<br />\nline<br />\n\tlazy</p>\n</blockquote>\n<pre><code>code &lt;b&gt;\n</code></pre>\n";
    check(md, expected);
}

#[test]
fn deep_nesting() {
    // Deep inline nesting must neither overflow the stack nor be quadratic.
    let n = 20_000;
    let md = format!("{}a{}", "*a ".repeat(n), "* ".repeat(n));
    let html = to_html(&md);
    assert!(html.starts_with("<p>"));
    let md = format!("{}x](/u)", "[".repeat(n));
    let _ = to_html(&md);
    let md = "> ".repeat(300) + "x\n";
    assert_eq!(to_html(&md).matches("<blockquote>").count(), 300);
}

#[test]
fn tree_api() {
    let doc = Document::parse("- a *b*\n");
    let list = doc.children(doc.root()).next().unwrap();
    match doc.node(list).kind() {
        NodeKind::List(l) => assert!(l.tight && !l.ordered && l.marker == '-'),
        k => panic!("unexpected {k:?}"),
    }
    let item = doc.node(list).first_child().unwrap();
    let para = doc.node(item).first_child().unwrap();
    assert_eq!(doc.node(para).parent(), Some(item));
    let kinds: Vec<_> = doc.children(para).map(|c| doc.node(c).kind().clone()).collect();
    assert_eq!(kinds[0], NodeKind::Text("a ".into()));
    assert_eq!(kinds[1], NodeKind::Emph);
    assert_eq!(doc.to_html(), "<ul>\n<li>a <em>b</em></li>\n</ul>\n");
}
