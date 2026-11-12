/**
 * Conformance tests for the Markdown converter.
 *
 * The expected outputs were produced by `cmark` 0.31.2 with default options.
 */
module sitegen.markdown.conformance;

version (unittest)
{
    import sitegen.markdown : markdownToHtml;

    private struct Case
    {
        string name;
        string markdown;
        string html;
    }

    private immutable Case[] cases = [
        Case("thematic breaks", "***\n---\n___\n - - -\n",
             "<hr />\n<hr />\n<hr />\n<hr />\n"),
        Case("atx headings", "# h1\n## h2 ##\n###### h6\n####### no\n#\n# foo#\n# foo \\#\n### ###\n",
             "<h1>h1</h1>\n<h2>h2</h2>\n<h6>h6</h6>\n<p>####### no</p>\n<h1></h1>\n<h1>foo#</h1>\n<h1>foo #</h1>\n<h3></h3>\n"),
        Case("setext", "Foo *bar*\n=========\n\nBaz\nqux\n---\n",
             "<h1>Foo <em>bar</em></h1>\n<h2>Baz\nqux</h2>\n"),
        Case("setext under quote", "> foo\n---\n",
             "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n"),
        Case("indented code", "    a\n\n      b\n    c  \n\n\n",
             "<pre><code>a\n\n  b\nc  \n</code></pre>\n"),
        Case("fenced code", "```ruby startline=3\ndef foo(x)\n  return 3\nend\n```\n\n~~~\n<>\n~~~\n\n  ```\n  aaa\n    bbb\n  ```\n\n```\nunclosed\n",
             "<pre><code class=\"language-ruby\">def foo(x)\n  return 3\nend\n</code></pre>\n<pre><code>&lt;&gt;\n</code></pre>\n<pre><code>aaa\n  bbb\n</code></pre>\n<pre><code>unclosed\n</code></pre>\n"),
        Case("info string", "``` language-foo\nx\n```\n\n~~~ a&amp;b\\*c d\ny\n~~~\n",
             "<pre><code class=\"language-foo\">x\n</code></pre>\n<pre><code class=\"language-a&amp;b*c\">y\n</code></pre>\n"),
        Case("paragraph continuation", "aaa\n   bbb\n\t\tccc\n\nddd\n\n\neee\n",
             "<p>aaa\nbbb\nccc</p>\n<p>ddd</p>\n<p>eee</p>\n"),
        Case("block quotes", "> # Foo\n> bar\nbaz\n\n>\n> a\n>\n\n> a\n>> b\n> c\n",
             "<blockquote>\n<h1>Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n<blockquote>\n<p>a</p>\n<blockquote>\n<p>b\nc</p>\n</blockquote>\n</blockquote>\n"),
        Case("tight list", "- a\n- b\n  - c\n- d\n",
             "<ul>\n<li>a</li>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n"),
        Case("loose list", "- a\n\n- b\n- c\n",
             "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n"),
        Case("loose via inner blank", "- a\n\n  b\n- c\n",
             "<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n"),
        Case("ordered lists", "3. three\n4. four\n\n1) a\n2) b\n\n0. zero\n",
             "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n<ol start=\"0\">\n<li>zero</li>\n</ol>\n"),
        Case("list kinds change", "- a\n- b\n* c\n+ d\n1. x\n1) y\n",
             "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ul>\n<li>c</li>\n</ul>\n<ul>\n<li>d</li>\n</ul>\n<ol>\n<li>x</li>\n</ol>\n<ol>\n<li>y</li>\n</ol>\n"),
        Case("list interrupts paragraph", "foo\n- bar\n\nbaz\n2. no\n1. yes\n",
             "<p>foo</p>\n<ul>\n<li>bar</li>\n</ul>\n<p>baz\n2. no</p>\n<ol>\n<li>yes</li>\n</ol>\n"),
        Case("empty items", "-\n- a\n-\n\n1.\n2. b\n",
             "<ul>\n<li></li>\n<li>a</li>\n<li></li>\n</ul>\n<ol>\n<li></li>\n<li>b</li>\n</ol>\n"),
        Case("item with code", "- a\n- ```\n  b\n  ```\n- c\n",
             "<ul>\n<li>a</li>\n<li>\n<pre><code>b\n</code></pre>\n</li>\n<li>c</li>\n</ul>\n"),
        Case("nested quote in list", "1. > a\n   > b\n2. c\n",
             "<ol>\n<li>\n<blockquote>\n<p>a\nb</p>\n</blockquote>\n</li>\n<li>c</li>\n</ol>\n"),
        Case("tabs in lists", "-\tfoo\n\n\tbar\n\n- foo\n\n\t\tbar\n",
             "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n<li>\n<p>foo</p>\n<pre><code>  bar\n</code></pre>\n</li>\n</ul>\n"),
        Case("lazy continuation", "> a\nb\n\n- a\nb\n\n- a\n  - b\nc\n",
             "<blockquote>\n<p>a\nb</p>\n</blockquote>\n<ul>\n<li>\n<p>a\nb</p>\n</li>\n<li>\n<p>a</p>\n<ul>\n<li>b\nc</li>\n</ul>\n</li>\n</ul>\n"),
        Case("blank after hr in item", "- a\n- ***\n\n- c\n",
             "<ul>\n<li>a</li>\n<li>\n<hr />\n</li>\n<li>c</li>\n</ul>\n"),
        Case("emphasis", "*a* _b_ **c** __d__ ***e*** *a **b** c* a*b*c _a_b_ foo*bar* *foo**bar**baz*\n",
             "<p><em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong> <em><strong>e</strong></em> <em>a <strong>b</strong> c</em> a<em>b</em>c <em>a_b</em> foo<em>bar</em> <em>foo<strong>bar</strong>baz</em></p>\n"),
        Case("emphasis flanking", "a * b * c\n\n_ a _\n\n**foo bar **\n\n*(*foo*)*\n\n_foo_bar\n\n*a _b* c_\n",
             "<p>a * b * c</p>\n<p>_ a _</p>\n<p>**foo bar **</p>\n<p><em>(<em>foo</em>)</em></p>\n<p>_foo_bar</p>\n<p><em>a _b</em> c_</p>\n"),
        Case("rule of three", "*foo**bar*\n\n**foo*bar*\n\n***foo** bar*\n\n*foo **bar***\n\n**foo*\n",
             "<p><em>foo**bar</em></p>\n<p>**foo<em>bar</em></p>\n<p><em><strong>foo</strong> bar</em></p>\n<p><em>foo <strong>bar</strong></em></p>\n<p>*<em>foo</em></p>\n"),
        Case("code spans", "`a` ``b ` c`` ` x ` `` ` ``\n\n`foo\nbar  \nbaz`\n\n`not closed\n\n```x``` ``y`\n",
             "<p><code>a</code> <code>b ` c</code> <code>x</code> <code>`</code></p>\n<p><code>foo bar   baz</code></p>\n<p>`not closed</p>\n<p><code>x</code> ``y`</p>\n"),
        Case("backslashes", "\\*not\\* \\\\ \\a \\_ \\` \\[x\\]\n\nline\\\nbreak\n",
             "<p>*not* \\ \\a _ ` [x]</p>\n<p>line<br />\nbreak</p>\n"),
        Case("entities", "&amp; &lt; &gt; &quot; &#35; &#x22; &#X41; &#0; &#xD800; &foo; &#12345678; &amp\n",
             "<p>&amp; &lt; &gt; &quot; # &quot; A � � &amp;foo; &amp;#12345678; &amp;amp</p>\n"),
        Case("hard breaks", "a  \nb\\\nc\nd   \ne\n",
             "<p>a<br />\nb<br />\nc\nd<br />\ne</p>\n"),
        Case("links", "[a](/u) [b](/u \"t\") [c](</a b> 'x') [d](/u (p)) [](<>) [e]() [f](a(b)c) [g](a\\)b)\n",
             "<p><a href=\"/u\">a</a> <a href=\"/u\" title=\"t\">b</a> <a href=\"/a%20b\" title=\"x\">c</a> <a href=\"/u\" title=\"p\">d</a> <a href=\"\"></a> <a href=\"\">e</a> <a href=\"a(b)c\">f</a> <a href=\"a)b\">g</a></p>\n"),
        Case("link titles", "[a](/u \"t\\\"q\") [b](/u 'it''s') [c](/u \"\")\n",
             "<p><a href=\"/u\" title=\"t&quot;q\">a</a> [b](/u 'it''s') <a href=\"/u\" title=\"\">c</a></p>\n"),
        Case("links with emphasis", "[*a* **b**](/u) *[a](/u)* [a *b](/u) c*\n",
             "<p><a href=\"/u\"><em>a</em> <strong>b</strong></a> <em><a href=\"/u\">a</a></em> <a href=\"/u\">a *b</a> c*</p>\n"),
        Case("nested brackets", "[x [a](/b) y](/d) [[a]](/b) ![[a](/b)](/c)\n",
             "<p>[x <a href=\"/b\">a</a> y](/d) <a href=\"/b\">[a]</a> <img src=\"/c\" alt=\"a\" /></p>\n"),
        Case("images", "![alt *em* `code`](/i.png \"t\") ![a](<b c>) ![](x)\n",
             "<p><img src=\"/i.png\" alt=\"alt em code\" title=\"t\" /> <img src=\"b%20c\" alt=\"a\" /> <img src=\"x\" alt=\"\" /></p>\n"),
        Case("unsafe urls", "[a](javascript:x) [b](JavaScript:y) [c](data:text/html,x) ![d](data:image/png;base64,AA) [e](file:///x) [f](vbscript:z)\n",
             "<p><a href=\"\">a</a> <a href=\"\">b</a> <a href=\"\">c</a> <img src=\"data:image/png;base64,AA\" alt=\"d\" /> <a href=\"\">e</a> <a href=\"\">f</a></p>\n"),
        Case("url encoding", "[a](/a b%20c?d=1&e='f'\"g) [b](/é) [c](/[x]) [d](/a\\*b)\n",
             "<p>[a](/a b%20c?d=1&amp;e='f'&quot;g) <a href=\"/%C3%A9\">b</a> <a href=\"/%5Bx%5D\">c</a> <a href=\"/a*b\">d</a></p>\n"),
        Case("autolinks", "<http://a.b/c?d=1&e> <mailto:x@y.z> <me@example.com> <a+b@c-d.org> <foo:bar> <x:> < http://no>\n",
             "<p><a href=\"http://a.b/c?d=1&amp;e\">http://a.b/c?d=1&amp;e</a> <a href=\"mailto:x@y.z\">mailto:x@y.z</a> <a href=\"mailto:me@example.com\">me@example.com</a> <a href=\"mailto:a+b@c-d.org\">a+b@c-d.org</a> <a href=\"foo:bar\">foo:bar</a> &lt;x:&gt; &lt; http://no&gt;</p>\n"),
        Case("not links", "[a] [b][c] [d][] (e) ![f] []( x)\n",
             "<p>[a] [b][c] [d][] (e) ![f] <a href=\"x\"></a></p>\n"),
        Case("mixed document", "# Title\n\nSome *text* with a [link](/x).\n\n- one\n- two\n\n> quote\n\n```\ncode\n```\n",
             "<h1>Title</h1>\n<p>Some <em>text</em> with a <a href=\"/x\">link</a>.</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<blockquote>\n<p>quote</p>\n</blockquote>\n<pre><code>code\n</code></pre>\n"),
        Case("deep nesting", "> - > 1. > - a\n>   > b\n",
             "<blockquote>\n<ul>\n<li>\n<blockquote>\n<ol>\n<li>\n<blockquote>\n<ul>\n<li>a\nb</li>\n</ul>\n</blockquote>\n</li>\n</ol>\n</blockquote>\n</li>\n</ul>\n</blockquote>\n"),
        Case("unicode", "héllo *wörld* `ünï` [lïnk](/ü \"tïtle\") — ok\n",
             "<p>héllo <em>wörld</em> <code>ünï</code> <a href=\"/%C3%BC\" title=\"tïtle\">lïnk</a> — ok</p>\n"),
        Case("empty", "",
             ""),
        Case("only blank lines", "\n  \n\t\n",
             ""),
        Case("no trailing newline", "a\nb",
             "<p>a\nb</p>\n"),
        Case("heading content spaces", "#    foo    \n\n#\tbar\t#\t\n",
             "<h1>foo</h1>\n<h1>bar</h1>\n"),
        Case("code in quote", ">     code\n>\n>     more\n",
             "<blockquote>\n<pre><code>code\n\nmore\n</code></pre>\n</blockquote>\n"),
        Case("fence in list", "1. a\n\n   ```\n   code\n\n   more\n   ```\n2. b\n",
             "<ol>\n<li>\n<p>a</p>\n<pre><code>code\n\nmore\n</code></pre>\n</li>\n<li>\n<p>b</p>\n</li>\n</ol>\n"),
        Case("html chars", "1 < 2 > 0 & 3 \"q\" 'a'\n",
             "<p>1 &lt; 2 &gt; 0 &amp; 3 &quot;q&quot; 'a'</p>\n"),
        Case("table-like", "a | b\n--|--\n1 | 2\n",
             "<p>a | b\n--|--\n1 | 2</p>\n"),
        Case("setext multi-line", "a\nb\nc\n===\n",
             "<h1>a\nb\nc</h1>\n"),
        Case("thematic in list", "- a\n- b\n\n  ***\n",
             "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n<hr />\n</li>\n</ul>\n"),
        Case("bullet after hr", "* a\n***\n* b\n",
             "<ul>\n<li>a</li>\n</ul>\n<hr />\n<ul>\n<li>b</li>\n</ul>\n"),
        Case("ol start big", "123456789. a\n1234567890. b\n",
             "<ol start=\"123456789\">\n<li>a\n1234567890. b</li>\n</ol>\n"),
        Case("indented list continuation", "- a\n    b\n- c\n      d\n",
             "<ul>\n<li>a\nb</li>\n<li>c\nd</li>\n</ul>\n"),
        Case("tab indent code", "\tcode\n\n- a\n\n\t\tcode\n",
             "<pre><code>code\n</code></pre>\n<ul>\n<li>\n<p>a</p>\n<pre><code>  code\n</code></pre>\n</li>\n</ul>\n"),
    ];

    unittest
    {
        foreach (c; cases)
        {
            const got = markdownToHtml(c.markdown);
            assert(got == c.html, "case '" ~ c.name ~ "': got\n" ~ got ~ "\nexpected\n" ~ c.html);
        }
    }
}
