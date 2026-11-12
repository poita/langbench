/**
 * HTML rendering of a block tree.
 *
 * The renderer walks the block tree once, in document order. The raw content
 * of each paragraph and heading is parsed into inlines on the way (with a
 * reusable `InlineParser`) and written out immediately; the inline walk is
 * iterative, so deeply nested emphasis and links are safe. The output matches
 * the `cmark` reference implementation byte for byte.
 */
module commonmark.html;

import commonmark.ast;
import commonmark.inline;
import commonmark.text;

/**
 * Renders a block tree (as returned by `parseBlocks`) to HTML.
 *
 * Returns: the HTML text.
 */
string renderHtml(Block document)
{
    auto r = HtmlRenderer(new InlineParser);
    r.renderBlock(document);
    return (() @trusted => cast(string) r.o.data)();
}

private struct HtmlRenderer
{
    Sink o;
    InlineParser inlines;

    this(InlineParser p)
    {
        inlines = p;
    }

    void cr()
    {
        const d = o.data;
        if (d.length != 0 && d[$ - 1] != '\n')
            o.put('\n');
    }

    void renderChildren(Block b)
    {
        for (Block c = b.firstChild; c !is null; c = c.next)
            renderBlock(c);
    }

    void renderBlock(Block b)
    {
        final switch (b.kind)
        {
        case BlockKind.document:
            renderChildren(b);
            break;
        case BlockKind.blockQuote:
            cr();
            o.put("<blockquote>\n");
            renderChildren(b);
            cr();
            o.put("</blockquote>\n");
            break;
        case BlockKind.list:
            cr();
            if (!b.ordered)
                o.put("<ul>\n");
            else if (b.start == 1)
                o.put("<ol>\n");
            else
            {
                import std.conv : to;

                o.put("<ol start=\"");
                o.put(b.start.to!string);
                o.put("\">\n");
            }
            renderChildren(b);
            o.put(b.ordered ? "</ol>\n" : "</ul>\n");
            break;
        case BlockKind.item:
            cr();
            o.put("<li>");
            renderChildren(b);
            o.put("</li>\n");
            break;
        case BlockKind.paragraph:
            {
                immutable tight = b.parent !is null && b.parent.parent !is null
                    && b.parent.parent.kind == BlockKind.list && b.parent.parent.tight;
                if (!tight)
                {
                    cr();
                    o.put("<p>");
                }
                renderInlines(b.text);
                if (!tight)
                    o.put("</p>\n");
            }
            break;
        case BlockKind.heading:
            {
                cr();
                immutable tag = cast(char)('0' + b.level);
                o.put("<h");
                o.put(tag);
                o.put('>');
                renderInlines(b.text);
                o.put("</h");
                o.put(tag);
                o.put(">\n");
            }
            break;
        case BlockKind.thematicBreak:
            cr();
            o.put("<hr />\n");
            break;
        case BlockKind.codeBlock:
            cr();
            if (b.info.length == 0)
                o.put("<pre><code>");
            else
            {
                size_t n = 0;
                while (n < b.info.length && !isSpace(b.info[n]))
                    ++n;
                const word = b.info[0 .. n];
                o.put("<pre><code class=\"");
                if (word.length < 9 || word[0 .. 9] != "language-")
                    o.put("language-");
                escapeHtml(o, word);
                o.put("\">");
            }
            escapeHtml(o, b.text);
            o.put("</code></pre>\n");
            break;
        }
    }

    void renderInlines(string content)
    {
        const nodes = inlines.parse(content);
        int imageDepth = 0;
        int node = nodes[0].firstChild;
        while (node != noNode)
        {
            // Enter.
            const n = &nodes[node];
            final switch (n.kind)
            {
            case InlineKind.root:
                break;
            case InlineKind.text:
                escapeHtml(o, n.text);
                break;
            case InlineKind.softBreak:
                o.put(imageDepth ? " " : "\n");
                break;
            case InlineKind.lineBreak:
                o.put(imageDepth ? " " : "<br />\n");
                break;
            case InlineKind.code:
                if (imageDepth)
                    escapeHtml(o, n.text);
                else
                {
                    o.put("<code>");
                    escapeHtml(o, n.text);
                    o.put("</code>");
                }
                break;
            case InlineKind.emph:
                if (!imageDepth)
                    o.put("<em>");
                break;
            case InlineKind.strong:
                if (!imageDepth)
                    o.put("<strong>");
                break;
            case InlineKind.link:
                if (!imageDepth)
                {
                    o.put("<a href=\"");
                    escapeHref(o, n.text);
                    o.put('"');
                    if (n.hasTitle)
                    {
                        o.put(" title=\"");
                        escapeHtml(o, n.title);
                        o.put('"');
                    }
                    o.put('>');
                }
                break;
            case InlineKind.image:
                if (imageDepth == 0)
                {
                    o.put("<img src=\"");
                    escapeHref(o, n.text);
                    o.put("\" alt=\"");
                }
                ++imageDepth;
                break;
            }
            if (n.firstChild != noNode)
            {
                node = n.firstChild;
                continue;
            }
            // Leave this node, and any ancestors that end here.
            for (;;)
            {
                const m = &nodes[node];
                switch (m.kind)
                {
                case InlineKind.emph:
                    if (!imageDepth)
                        o.put("</em>");
                    break;
                case InlineKind.strong:
                    if (!imageDepth)
                        o.put("</strong>");
                    break;
                case InlineKind.link:
                    if (!imageDepth)
                        o.put("</a>");
                    break;
                case InlineKind.image:
                    if (--imageDepth == 0)
                    {
                        o.put('"');
                        if (m.hasTitle)
                        {
                            o.put(" title=\"");
                            escapeHtml(o, m.title);
                            o.put('"');
                        }
                        o.put(" />");
                    }
                    break;
                default:
                    break;
                }
                if (m.next != noNode)
                {
                    node = m.next;
                    break;
                }
                node = m.parent;
                if (node == 0)
                {
                    node = noNode;
                    break;
                }
            }
        }
    }
}

unittest
{
    import commonmark.block : parseBlocks;

    static string html(string md)
    {
        return renderHtml(parseBlocks(md));
    }

    assert(html("") == "");
    assert(html("# Title #\n") == "<h1>Title</h1>\n");
    assert(html("a *b*\n") == "<p>a <em>b</em></p>\n");
    assert(html("- a\n- b\n") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
    assert(html("- a\n\n- b\n") == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n");
    assert(html("> q\n") == "<blockquote>\n<p>q</p>\n</blockquote>\n");
    assert(html("```c++ x\n<&>\n```\n") == "<pre><code class=\"language-c++\">&lt;&amp;&gt;\n</code></pre>\n");
    assert(html("![a *b* `c`](/i.png \"t\")") == "<p><img src=\"/i.png\" alt=\"a b c\" title=\"t\" /></p>\n");
    assert(html("[j](javascript:x)") == "<p><a href=\"\">j</a></p>\n");
    assert(html("3. a\n") == "<ol start=\"3\">\n<li>a</li>\n</ol>\n");
}
