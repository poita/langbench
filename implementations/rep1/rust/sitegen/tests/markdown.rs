//! Markdown conversion tests.
//!
//! Every expected output below was produced by the reference implementation,
//! `cmark` 0.31.2 with default options, for the input beside it. The inputs
//! stay within the subset the converter supports (no HTML, no link reference
//! definitions, only the four named entities `amp`, `lt`, `gt`, `quot`).

use sitegen::markdown::to_html;

fn check(name: &str, input: &str, expected: &str) {
    let got = to_html(input);
    assert_eq!(got, expected, "case `{}`\ninput: {:?}", name, input);
}

#[test]
fn matches_cmark() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "thematic_breaks",
            r#"***
---
___
 - - -
_ _ _ _
"#,
            r#"<hr />
<hr />
<hr />
<hr />
<hr />
"#,
        ),
        (
            "atx_headings",
            r#"# one
## two ##
###### six
####### seven
#hashtag
# foo#
# foo \#
#
### ###
"#,
            r#"<h1>one</h1>
<h2>two</h2>
<h6>six</h6>
<p>####### seven
#hashtag</p>
<h1>foo#</h1>
<h1>foo #</h1>
<h1></h1>
<h3></h3>
"#,
        ),
        (
            "setext_headings",
            r#"Foo *bar*
=========

Multi
line
---
"#,
            r#"<h1>Foo <em>bar</em></h1>
<h2>Multi
line</h2>
"#,
        ),
        (
            "indented_code",
            r#"    a


    b  

"#,
            r#"<pre><code>a


b  
</code></pre>
"#,
        ),
        (
            "indented_code_not_interrupting_paragraph",
            r#"Foo
    bar
"#,
            r#"<p>Foo
bar</p>
"#,
        ),
        (
            "fenced_code_info",
            r#"```rust extra
fn main() {}
```

~~~ language-x
<tag> & "q"
~~~
"#,
            r#"<pre><code class="language-rust">fn main() {}
</code></pre>
<pre><code class="language-x">&lt;tag&gt; &amp; &quot;q&quot;
</code></pre>
"#,
        ),
        (
            "fenced_code_unclosed_and_indented",
            r#"  ```
  a
   b
 c
"#,
            r#"<pre><code>a
 b
c
</code></pre>
"#,
        ),
        (
            "fenced_code_closing_needs_length",
            r#"````
```
x
````
"#,
            r#"<pre><code>```
x
</code></pre>
"#,
        ),
        (
            "paragraphs_and_soft_breaks",
            r#"one
two

  three   
"#,
            r#"<p>one
two</p>
<p>three</p>
"#,
        ),
        (
            "hard_breaks",
            r#"a  
b\
c

last\"#,
            r#"<p>a<br />
b<br />
c</p>
<p>last\</p>
"#,
        ),
        (
            "block_quotes",
            r#"> a
> b

> c
lazy

> > nested
>
> back
"#,
            r#"<blockquote>
<p>a
b</p>
</blockquote>
<blockquote>
<p>c
lazy</p>
</blockquote>
<blockquote>
<blockquote>
<p>nested</p>
</blockquote>
<p>back</p>
</blockquote>
"#,
        ),
        (
            "block_quote_interrupts_and_setext",
            r#"> foo
---

- foo
---
"#,
            r#"<blockquote>
<p>foo</p>
</blockquote>
<hr />
<ul>
<li>foo</li>
</ul>
<hr />
"#,
        ),
        (
            "bullet_lists_tight_loose",
            r#"- a
- b


- c

* x
* y
"#,
            r#"<ul>
<li>
<p>a</p>
</li>
<li>
<p>b</p>
</li>
<li>
<p>c</p>
</li>
</ul>
<ul>
<li>x</li>
<li>y</li>
</ul>
"#,
        ),
        (
            "list_changes_marker",
            r#"- a
+ b
* c
"#,
            r#"<ul>
<li>a</li>
</ul>
<ul>
<li>b</li>
</ul>
<ul>
<li>c</li>
</ul>
"#,
        ),
        (
            "ordered_lists",
            r#"3. three
4. four

1) one
2) two

0. zero
"#,
            r#"<ol start="3">
<li>three</li>
<li>four</li>
</ol>
<ol>
<li>one</li>
<li>two</li>
</ol>
<ol start="0">
<li>zero</li>
</ol>
"#,
        ),
        (
            "list_interrupting_paragraph",
            r#"foo
2. not a list
1. a list
- also
"#,
            r#"<p>foo
2. not a list</p>
<ol>
<li>a list</li>
</ol>
<ul>
<li>also</li>
</ul>
"#,
        ),
        (
            "nested_lists",
            r#"- a
  - b
    - c
  - d
- e

1. x
   - y
"#,
            r#"<ul>
<li>a
<ul>
<li>b
<ul>
<li>c</li>
</ul>
</li>
<li>d</li>
</ul>
</li>
<li>e</li>
</ul>
<ol>
<li>x
<ul>
<li>y</li>
</ul>
</li>
</ol>
"#,
        ),
        (
            "list_item_code_and_paragraphs",
            r#"1.  a

    b

        code
"#,
            r#"<ol>
<li>
<p>a</p>
<p>b</p>
<pre><code>code
</code></pre>
</li>
</ol>
"#,
        ),
        (
            "empty_list_items",
            r#"-
- b
-

1.
2. two
"#,
            r#"<ul>
<li></li>
<li>b</li>
<li></li>
</ul>
<ol>
<li></li>
<li>two</li>
</ol>
"#,
        ),
        (
            "tabs_in_lists",
            r#"-	foo

	bar

- 	baz

>	quote
"#,
            r#"<ul>
<li>
<p>foo</p>
<p>bar</p>
</li>
<li>
<p>baz</p>
</li>
</ul>
<blockquote>
<p>quote</p>
</blockquote>
"#,
        ),
        (
            "tight_list_with_thematic_break",
            r#"- a
  ***

  b
"#,
            r#"<ul>
<li>a
<hr />
b</li>
</ul>
"#,
        ),
        (
            "blank_line_inside_item_code",
            r#"- ```
  a

  b
  ```
- c
"#,
            r#"<ul>
<li>
<pre><code>a

b
</code></pre>
</li>
<li>c</li>
</ul>
"#,
        ),
        (
            "backslash_escapes",
            r#"\*not emph\* \# \\ \a \<
"#,
            r#"<p>*not emph* # \ \a &lt;</p>
"#,
        ),
        (
            "entities",
            r#"&amp; &lt; &gt; &quot; &#65; &#x41; &#0; &#xD800; &foo; &#12345678; &amp
"#,
            r#"<p>&amp; &lt; &gt; &quot; A A � � &amp;foo; &amp;#12345678; &amp;amp</p>
"#,
        ),
        (
            "code_spans",
            r#"`a` ``b ` c`` ` x ` `  ` `` ` ``

```not closed
"#,
            r#"<p><code>a</code> <code>b ` c</code> <code>x</code> <code>  </code> <code>`</code></p>
<pre><code class="language-not"></code></pre>
"#,
        ),
        (
            "code_span_memo",
            r#"`` ` `` ``` `` ` ``
"#,
            r#"<p><code>`</code> ``` <code>`</code></p>
"#,
        ),
        (
            "emphasis_basic",
            r#"*a* _b_ **c** __d__ ***e*** *a **b** c* **a *b* c**
"#,
            r#"<p><em>a</em> <em>b</em> <strong>c</strong> <strong>d</strong> <em><strong>e</strong></em> <em>a <strong>b</strong> c</em> <strong>a <em>b</em> c</strong></p>
"#,
        ),
        (
            "emphasis_flanking",
            r#"a * b * c _ d _ e snake_case_word 2*3*4 *(a)* _(b)_
"#,
            r#"<p>a * b * c _ d _ e snake_case_word 2<em>3</em>4 <em>(a)</em> <em>(b)</em></p>
"#,
        ),
        (
            "emphasis_rule_of_three",
            r#"*foo**bar**baz*

***foo** bar*

*foo**bar***
"#,
            r#"<p><em>foo<strong>bar</strong>baz</em></p>
<p><em><strong>foo</strong> bar</em></p>
<p><em>foo<strong>bar</strong></em></p>
"#,
        ),
        (
            "emphasis_unmatched",
            r#"**foo* *bar** _a *b_ c*
"#,
            r#"<p><em><em>foo</em> <em>bar</em></em> <em>a *b</em> c*</p>
"#,
        ),
        (
            "links_basic",
            r#"[a](/u) [b](/u "t") [c](/u 't') [d](/u (t)) [e]() [f](<>)
"#,
            r#"<p><a href="/u">a</a> <a href="/u" title="t">b</a> <a href="/u" title="t">c</a> <a href="/u" title="t">d</a> <a href="">e</a> <a href="">f</a></p>
"#,
        ),
        (
            "links_destination_forms",
            r#"[a](</my uri>) [b](/a(b)c) [c](/a\)b) [d](a%20b) [e](/ü) [f](<a\>b>)
"#,
            r#"<p><a href="/my%20uri">a</a> <a href="/a(b)c">b</a> <a href="/a)b">c</a> <a href="a%20b">d</a> <a href="/%C3%BC">e</a> <a href="a%3Eb">f</a></p>
"#,
        ),
        (
            "links_titles_and_escapes",
            r#"[a](/u "t\"x") [b](/u "multi
line") [c](/u "&quot;") [d](/u&amp;v)
"#,
            r#"<p><a href="/u" title="t&quot;x">a</a> <a href="/u" title="multi
line">b</a> <a href="/u" title="&quot;">c</a> <a href="/u&amp;v">d</a></p>
"#,
        ),
        (
            "links_not_nested",
            r#"[a [b](/b) c](/a)

[x ![i](/i) y](/x)

[a [q] b](/c)
"#,
            r#"<p>[a <a href="/b">b</a> c](/a)</p>
<p><a href="/x">x <img src="/i" alt="i" /> y</a></p>
<p><a href="/c">a [q] b</a></p>
"#,
        ),
        (
            "links_invalid",
            r#"[a](/my uri) [b](/u "t" x) [c] (/u) [d](
"#,
            r#"<p>[a](/my uri) [b](/u &quot;t&quot; x) [c] (/u) [d](</p>
"#,
        ),
        (
            "links_unsafe_schemes",
            r#"[a](javascript:x) [b](JAVASCRIPT:x) [c](data:text/html,x) [d](data:image/png;base64,AA) [e](file:///x)
"#,
            r#"<p><a href="">a</a> <a href="">b</a> <a href="">c</a> <a href="data:image/png;base64,AA">d</a> <a href="">e</a></p>
"#,
        ),
        (
            "links_href_encoding",
            r#"[a](/a b?x=1&y=2'z"q) [b](</a b>) [c](/éü)
"#,
            r#"<p>[a](/a b?x=1&amp;y=2'z&quot;q) <a href="/a%20b">b</a> <a href="/%C3%A9%C3%BC">c</a></p>
"#,
        ),
        (
            "images",
            r#"![alt *em* `code`](/i.png "title") ![a [b](/c) d](/e) ![](/f)

![soft
break](/g)
"#,
            r#"<p><img src="/i.png" alt="alt em code" title="title" /> <img src="/e" alt="a b d" /> <img src="/f" alt="" /></p>
<p><img src="/g" alt="soft break" /></p>
"#,
        ),
        (
            "autolinks",
            r#"<http://a.b/c?d=e&f> <mailto:x@y.z> <foo@bar.baz> <a:b> < not a link> a< b <-x <3 <
"#,
            r#"<p><a href="http://a.b/c?d=e&amp;f">http://a.b/c?d=e&amp;f</a> <a href="mailto:x@y.z">mailto:x@y.z</a> <a href="mailto:foo@bar.baz">foo@bar.baz</a> &lt;a:b&gt; &lt; not a link&gt; a&lt; b &lt;-x &lt;3 &lt;</p>
"#,
        ),
        (
            "lt_and_other_text",
            r#"1 < 2 > 1 <> <3 <-- -->
"#,
            r#"<p>1 &lt; 2 &gt; 1 &lt;&gt; &lt;3 &lt;-- --&gt;</p>
"#,
        ),
        (
            "unicode_text",
            r#"héllo wörld ✓ 日本語 *é* _ü_
"#,
            r#"<p>héllo wörld ✓ 日本語 <em>é</em> <em>ü</em></p>
"#,
        ),
        (
            "lazy_continuation",
            r#"> a
b

- a
b

1. x
   y
z
"#,
            r#"<blockquote>
<p>a
b</p>
</blockquote>
<ul>
<li>a
b</li>
</ul>
<ol>
<li>x
y
z</li>
</ol>
"#,
        ),
        (
            "heading_in_container",
            r#"> # h
> text

- # h
  text
"#,
            r#"<blockquote>
<h1>h</h1>
<p>text</p>
</blockquote>
<ul>
<li>
<h1>h</h1>
text</li>
</ul>
"#,
        ),
        (
            "spec_worked_example_1",
            r#"# Title #

Some *emphasis*, **strong**, `code` and a [link](</my uri> "t\"x").

- one
- two
  - nested

1. a

   b
2. c

> quote  
> line\
	lazy

    code <b>
"#,
            r#"<h1>Title</h1>
<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href="/my%20uri" title="t&quot;x">link</a>.</p>
<ul>
<li>one</li>
<li>two
<ul>
<li>nested</li>
</ul>
</li>
</ul>
<ol>
<li>
<p>a</p>
<p>b</p>
</li>
<li>
<p>c</p>
</li>
</ol>
<blockquote>
<p>quote<br />
line<br />
	lazy</p>
</blockquote>
<pre><code>code &lt;b&gt;
</code></pre>
"#,
        ),
        (
            "spec_worked_example_2",
            r#"*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)
<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \*lit\* a\
b
"#,
            r#"<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> <img src="/i.png" alt="alt x y" />
<a href="http://a.b/?x=1&amp;y=2">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB� *lit* a<br />
b</p>
"#,
        ),
        (
            "spec_worked_example_3",
            r#"- a
- ```py
  x = "<>"
  ```
- c

  d
* e
***
Foo
---
[j](javascript:alert(1)) [k](/x "") [](<>)
"#,
            r#"<ul>
<li>
<p>a</p>
</li>
<li>
<pre><code class="language-py">x = &quot;&lt;&gt;&quot;
</code></pre>
</li>
<li>
<p>c</p>
<p>d</p>
</li>
</ul>
<ul>
<li>e</li>
</ul>
<hr />
<h2>Foo</h2>
<p><a href="">j</a> <a href="/x" title="">k</a> <a href=""></a></p>
"#,
        ),
        ("empty_and_blank_documents", r#""#, r#""#),
        (
            "only_blank_lines",
            r#"

  
	
"#,
            r#""#,
        ),
    ];
    for (name, input, expected) in cases {
        check(name, input, expected);
    }
}

#[test]
fn empty_input_gives_empty_output() {
    assert_eq!(to_html(""), "");
    assert_eq!(to_html("\n\n"), "");
}

#[test]
fn non_empty_output_ends_with_newline() {
    for src in ["a", "a\n", "# h", "- x", "> q", "```\nx", "***"] {
        assert!(to_html(src).ends_with('\n'), "{:?}", src);
    }
}

#[test]
fn no_trailing_newline_is_the_same_as_one() {
    for src in [
        "a\nb",
        "- a\n- b",
        "> a\n> b",
        "```\ncode\n```",
        "    code",
        "# h #",
        "a  \nb",
    ] {
        assert_eq!(to_html(src), to_html(&format!("{}\n", src)), "{:?}", src);
    }
}

#[test]
fn deeply_nested_input_does_not_overflow() {
    // Block quotes 300 deep, and 5000 unmatched brackets, are both fine.
    let handle = std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let quotes = format!("{}deep\n", "> ".repeat(300));
            assert_eq!(to_html(&quotes).matches("<blockquote>").count(), 300);
            let brackets = format!("{}{}\n", "[".repeat(5000), "]".repeat(5000));
            assert!(to_html(&brackets).starts_with("<p>[["));
            let emphasis = format!("{}x{}\n", "*a ".repeat(3000), "* ".repeat(3000));
            assert!(to_html(&emphasis).contains("<em>"));
        })
        .unwrap();
    handle.join().unwrap();
}
