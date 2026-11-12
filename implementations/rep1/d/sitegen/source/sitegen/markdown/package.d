/**
 * A CommonMark-subset to HTML converter.
 *
 * The converter implements the subset of CommonMark 0.31.2 that static site
 * content needs: thematic breaks, ATX and setext headings, indented and
 * fenced code blocks, paragraphs, block quotes, lists, backslash escapes,
 * entity references, code spans, emphasis, inline links and images,
 * autolinks and line breaks.  Raw HTML, link reference definitions and
 * extensions are not supported.  The output is the same as that of `cmark`
 * with default options.
 *
 * Example:
 * ---
 * import sitegen.markdown;
 * assert(markdownToHtml("Hello *world*") == "<p>Hello <em>world</em></p>\n");
 * ---
 */
module sitegen.markdown;

public import sitegen.markdown.ast : Block, BlockKind, Inline, InlineKind;
public import sitegen.markdown.blocks : parseBlocks;
public import sitegen.markdown.inlines : parseInlines;
public import sitegen.markdown.html : renderHtml;

/**
 * Converts a Markdown document to HTML.
 *
 * Params:
 *   markdown = the document: UTF-8 text with LF line endings
 * Returns: the HTML, which ends with a newline unless the document is empty.
 */
string markdownToHtml(string markdown)
{
    return renderHtml(parseBlocks(markdown));
}

unittest
{
    assert(markdownToHtml("") == "");
    assert(markdownToHtml("Hello *world*") == "<p>Hello <em>world</em></p>\n");
    assert(markdownToHtml("# T #\n\ntext") == "<h1>T</h1>\n<p>text</p>\n");
    assert(markdownToHtml("- a\n- b\n") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
    assert(markdownToHtml("    code <b>\n") == "<pre><code>code &lt;b&gt;\n</code></pre>\n");
    assert(markdownToHtml("> q\n") == "<blockquote>\n<p>q</p>\n</blockquote>\n");
    assert(markdownToHtml("***\n") == "<hr />\n");
}
