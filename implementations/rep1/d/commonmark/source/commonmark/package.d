/**
 * A CommonMark (subset) to HTML converter.
 *
 * The library converts a Markdown document to the HTML produced by the
 * `cmark` reference implementation 0.31.2. It is organised in three stages,
 * each in its own module:
 *
 * $(UL
 *   $(LI `commonmark.block`: line-by-line parsing into a tree of `Block`s
 *        (`commonmark.ast`).)
 *   $(LI `commonmark.inline`: parsing the text of paragraphs and headings into
 *        inline nodes (emphasis, links, code spans, ...).)
 *   $(LI `commonmark.html`: rendering the tree to HTML.)
 * )
 *
 * Supported: ATX and setext headings, thematic breaks, indented and fenced
 * code blocks, paragraphs, block quotes, lists, backslash escapes, entities
 * (numeric ones and `&amp;` `&lt;` `&gt;` `&quot;`), code spans, emphasis,
 * inline links and images, autolinks, hard and soft line breaks. Raw HTML,
 * link reference definitions and extensions are not supported.
 *
 * Example:
 * ---
 * import commonmark;
 * assert(toHtml("Hello, *world*!") == "<p>Hello, <em>world</em>!</p>\n");
 * ---
 */
module commonmark;

public import commonmark.ast;
public import commonmark.block : parseBlocks;
public import commonmark.html : renderHtml;
public import commonmark.inline : InlineKind, InlineNode, InlineParser, noNode;

/**
 * Converts a Markdown document to HTML.
 *
 * Params:
 *     markdown = the document, as UTF-8 text with `\n` line endings
 *
 * Returns: the HTML, every line terminated by `\n` (empty for an empty document)
 */
string toHtml(string markdown)
{
    return renderHtml(parseBlocks(markdown));
}

///
unittest
{
    assert(toHtml("") == "");
    assert(toHtml("Hello, *world*!") == "<p>Hello, <em>world</em>!</p>\n");
    assert(toHtml("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
}
