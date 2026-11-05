package commonmark_test

import "testing"

func TestEmphasis(t *testing.T) {
	runCases(t, []convCase{
		{"em", "*a*", "<p><em>a</em></p>\n"},
		{"strong", "**a**", "<p><strong>a</strong></p>\n"},
		{"underscore", "_a_ __b__", "<p><em>a</em> <strong>b</strong></p>\n"},
		{"intraword underscore", "a_b_c", "<p>a_b_c</p>\n"},
		{"intraword star", "a*b*c", "<p>a<em>b</em>c</p>\n"},
		{"triple", "***a***", "<p><em><strong>a</strong></em></p>\n"},
		{"rule of three", "*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n"},
		{"rule of three 2", "*foo**bar*", "<p><em>foo**bar</em></p>\n"},
		{"not flanking", "a * b *", "<p>a * b *</p>\n"},
		{"nested", "**a *b* c**", "<p><strong>a <em>b</em> c</strong></p>\n"},
		{"unmatched", "**a*", "<p>*<em>a</em></p>\n"},
		{"punctuation flanking", "*(a)*", "<p><em>(a)</em></p>\n"},
		{"across newline", "*a\nb*", "<p><em>a\nb</em></p>\n"},
	})
}

func TestCodeSpans(t *testing.T) {
	runCases(t, []convCase{
		{"simple", "`a`", "<p><code>a</code></p>\n"},
		{"double", "`` a`b ``", "<p><code>a`b</code></p>\n"},
		{"strip one space", "`  a  `", "<p><code> a </code></p>\n"},
		{"all spaces kept", "` `", "<p><code> </code></p>\n"},
		{"newline to space", "`a\nb`", "<p><code>a b</code></p>\n"},
		{"unmatched", "`a", "<p>`a</p>\n"},
		{"length mismatch", "``a`", "<p>``a`</p>\n"},
		{"escaped html", "`<b>&`", "<p><code>&lt;b&gt;&amp;</code></p>\n"},
		{"no backslash escapes", "`\\*`", "<p><code>\\*</code></p>\n"},
		{"binds tighter than emphasis", "*a`*`", "<p>*a<code>*</code></p>\n"},
	})
}

func TestBreaksAndEscapes(t *testing.T) {
	runCases(t, []convCase{
		{"soft", "a\nb", "<p>a\nb</p>\n"},
		{"hard spaces", "a  \nb", "<p>a<br />\nb</p>\n"},
		{"one space is soft", "a \nb", "<p>a\nb</p>\n"},
		{"hard backslash", "a\\\nb", "<p>a<br />\nb</p>\n"},
		{"backslash at end", "a\\", "<p>a\\</p>\n"},
		{"leading spaces next line", "a\n    b", "<p>a\nb</p>\n"},
		{"escape punct", "\\*a\\* \\q", "<p>*a* \\q</p>\n"},
		{"escape in html", "\\<\\&\\\"", "<p>&lt;&amp;&quot;</p>\n"},
		{"entities", "&amp; &lt; &gt; &quot; &#65; &#x42; &#X43;", "<p>&amp; &lt; &gt; &quot; A B C</p>\n"},
		{"bad entities", "&foo; &#; &#x; &amp &#12345678;", "<p>&amp;foo; &amp;#; &amp;#x; &amp;amp &amp;#12345678;</p>\n"},
		{"replacement char", "&#0; &#xD800; &#x110000;", "<p>\uFFFD \uFFFD \uFFFD</p>\n"},
		{"lt is text", "a < b > c <3", "<p>a &lt; b &gt; c &lt;3</p>\n"},
		{"unicode", "é *ü*", "<p>é <em>ü</em></p>\n"},
	})
}

func TestLinksAndImages(t *testing.T) {
	runCases(t, []convCase{
		{"link", "[a](/b)", "<p><a href=\"/b\">a</a></p>\n"},
		{"title", "[a](/b \"t\")", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"single quote title", "[a](/b 't')", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"paren title", "[a](/b (t))", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"empty title kept", "[a](/b \"\")", "<p><a href=\"/b\" title=\"\">a</a></p>\n"},
		{"empty destination", "[a]()", "<p><a href=\"\">a</a></p>\n"},
		{"angle destination", "[a](</my uri>)", "<p><a href=\"/my%20uri\">a</a></p>\n"},
		{"space in bare destination", "[a](/my uri)", "<p>[a](/my uri)</p>\n"},
		{"parens balanced", "[a](/b(c))", "<p><a href=\"/b(c)\">a</a></p>\n"},
		{"parens unbalanced", "[a](/b(c)", "<p>[a](/b(c)</p>\n"},
		{"escaped title quote", "[a](/b \"t\\\"x\")", "<p><a href=\"/b\" title=\"t&quot;x\">a</a></p>\n"},
		{"newlines inside", "[a](\n/b\n\"t\"\n)", "<p><a href=\"/b\" title=\"t\">a</a></p>\n"},
		{"entity in destination", "[a](/b?x=1&amp;y=2)", "<p><a href=\"/b?x=1&amp;y=2\">a</a></p>\n"},
		{"escape then entity order", "[a](\\&amp;)", "<p><a href=\"&amp;\">a</a></p>\n"},
		{"emphasis inside", "[*a*](/b)", "<p><a href=\"/b\"><em>a</em></a></p>\n"},
		{"no links in links", "[a [b](/c)](/d)", "<p>[a <a href=\"/c\">b</a>](/d)</p>\n"},
		{"image in link", "[![i](/j)](/k)", "<p><a href=\"/k\"><img src=\"/j\" alt=\"i\" /></a></p>\n"},
		{"not a link without paren", "[a] [b][c]", "<p>[a] [b][c]</p>\n"},
		{"image", "![a *b* `c`](/i.png \"t\")", "<p><img src=\"/i.png\" alt=\"a b c\" title=\"t\" /></p>\n"},
		{"image alt nested", "![a ![b](/c) d](/e)", "<p><img src=\"/e\" alt=\"a b d\" /></p>\n"},
		{"image alt breaks", "![a\nb](/c)", "<p><img src=\"/c\" alt=\"a b\" /></p>\n"},
		{"javascript url", "[a](javascript:alert(1))", "<p><a href=\"\">a</a></p>\n"},
		{"JavaScript url", "[a](JaVaScRiPt:x)", "<p><a href=\"\">a</a></p>\n"},
		{"data url", "[a](data:text/html,x)", "<p><a href=\"\">a</a></p>\n"},
		{"data image url", "![a](data:image/png;base64,AA)", "<p><img src=\"data:image/png;base64,AA\" alt=\"a\" /></p>\n"},
		{"url encoding", "[a](</a b\"c[d]é'&>)", "<p><a href=\"/a%20b%22c%5Bd%5D%C3%A9&#x27;&amp;\">a</a></p>\n"},
		{"percent kept", "[a](/%20)", "<p><a href=\"/%20\">a</a></p>\n"},
		{"link_closed quirk", "[x [a](/b) ![i](/j) y](/d)", "<p>[x <a href=\"/b\">a</a> <img src=\"/j\" alt=\"i\" /> y](/d)</p>\n"},
		{"link_closed cleared", "[x [a](/b) ![i [q] j](/k) y](/d)", "<p><a href=\"/d\">x <a href=\"/b\">a</a> <img src=\"/k\" alt=\"i [q] j\" /> y</a></p>\n"},
		{"title longest match", "[a](/b \"x\\\" y\")", "<p><a href=\"/b\" title=\"x&quot; y\">a</a></p>\n"},
		{"dest then no space title", "[a](/b\"t\")", "<p><a href=\"/b%22t%22\">a</a></p>\n"},
	})
}

func TestAutolinks(t *testing.T) {
	runCases(t, []convCase{
		{"uri", "<http://a.b/c?d=1&e=2>", "<p><a href=\"http://a.b/c?d=1&amp;e=2\">http://a.b/c?d=1&amp;e=2</a></p>\n"},
		{"email", "<foo@bar.example.com>", "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n"},
		{"short scheme", "<a:b>", "<p>&lt;a:b&gt;</p>\n"},
		{"scheme ok", "<ab:>", "<p><a href=\"ab:\">ab:</a></p>\n"},
		{"space breaks", "<http://a b>", "<p>&lt;http://a b&gt;</p>\n"},
		{"no escapes", "<http://a\\*b>", "<p><a href=\"http://a%5C*b\">http://a\\*b</a></p>\n"},
		{"bad email", "<foo@-bar.com>", "<p>&lt;foo@-bar.com&gt;</p>\n"},
		{"entity decoded", "<http://a.b/?x&amp;y>", "<p><a href=\"http://a.b/?x&amp;y\">http://a.b/?x&amp;y</a></p>\n"},
	})
}
