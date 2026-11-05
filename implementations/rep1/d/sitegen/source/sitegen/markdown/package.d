/// A CommonMark-subset Markdown to HTML converter.
///
/// The converter reproduces what `cmark` 0.31.2 produces for headings,
/// paragraphs, lists, block quotes, code blocks, thematic breaks, emphasis,
/// code spans, links, images, autolinks, escapes and line breaks. Raw HTML,
/// link reference definitions and extensions are not supported.
///
/// ---
/// import sitegen.markdown;
/// assert(markdownToHtml("*hi*") == "<p><em>hi</em></p>\n");
/// ---
module sitegen.markdown;

public import sitegen.markdown.node : Node, NodeKind;
import sitegen.markdown.blocks : BlockParser;
import sitegen.markdown.html : renderHtml;
import sitegen.markdown.inlines : InlineParser;
import std.exception : assumeUnique;

/// Parse `source` into a document tree with inline nodes filled in.
Node parseMarkdown(string source)
{
    auto document = new BlockParser().parse(source);
    auto inlines = new InlineParser();
    parseInlinesIn(document, inlines);
    return document;
}

private void parseInlinesIn(Node n, InlineParser inlines)
{
    if (n.kind == NodeKind.paragraph || n.kind == NodeKind.heading)
    {
        string content = assumeUnique(n.content);
        n.content = null;
        inlines.parse(n, content);
        return;
    }
    for (Node c = n.firstChild; c !is null; c = c.next)
        parseInlinesIn(c, inlines);
}

/// Convert Markdown text to HTML. A non-empty document yields output that
/// ends with a newline; an empty document yields the empty string.
string markdownToHtml(string source)
{
    return renderHtml(parseMarkdown(source));
}
