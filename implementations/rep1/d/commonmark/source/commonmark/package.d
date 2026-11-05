/**
 * A CommonMark-to-HTML converter for the subset of CommonMark 0.31.2 that
 * covers thematic breaks, ATX/setext headings, indented/fenced code, block
 * quotes, lists, paragraphs, backslash escapes, entities, code spans,
 * emphasis, links, images, autolinks and line breaks. Raw HTML, link
 * reference definitions and extensions are not supported.
 *
 * The converter works in three stages, each in its own module:
 * $(UL
 *   $(LI `commonmark.blocks` builds the block structure line by line,)
 *   $(LI `commonmark.inlines` parses paragraph and heading content into
 *        inline nodes (delimiter stack, bracket stack, process-emphasis),)
 *   $(LI `commonmark.html` renders the tree to HTML.))
 *
 * Example:
 * ---
 * import commonmark;
 * assert(toHtml("Hello *world*") == "<p>Hello <em>world</em></p>\n");
 * ---
 */
module commonmark;

public import commonmark.ast : Block, BlockKind, Document;
public import commonmark.blocks : parseBlocks;
public import commonmark.buffer : Buffer;
public import commonmark.html : escapeHref, escapeHtml;

import commonmark.html : renderDocument;

/// Convert Markdown to HTML, appending the result to `output`.
void toHtml(const(char)[] markdown, ref Buffer output)
{
    auto doc = parseBlocks(markdown);
    renderDocument(doc, output);
}

/// Convert Markdown to an HTML string.
string toHtml(const(char)[] markdown)
{
    Buffer b;
    toHtml(markdown, b);
    return b.idup;
}
