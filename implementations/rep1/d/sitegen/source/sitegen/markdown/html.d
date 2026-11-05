/// Phase 3 of the Markdown conversion: rendering the tree as HTML.
module sitegen.markdown.html;

import sitegen.markdown.node;
import sitegen.markdown.text;
import std.array : Appender, appender;
import std.conv : to;

/// Render a finished document tree.
string renderHtml(Node document)
{
    auto r = HtmlRenderer(appender!(char[])());
    r.renderChildren(document);
    return r.out_.data.idup;
}

private struct HtmlRenderer
{
    Appender!(char[]) out_;

    void cr()
    {
        auto d = out_.data;
        if (d.length != 0 && d[$ - 1] != '\n')
            out_.put('\n');
    }

    void renderChildren(Node n)
    {
        for (Node c = n.firstChild; c !is null; c = c.next)
            render(c);
    }

    void render(Node n)
    {
        final switch (n.kind)
        {
        case NodeKind.document:
            renderChildren(n);
            break;
        case NodeKind.blockQuote:
            cr();
            out_.put("<blockquote>\n");
            renderChildren(n);
            cr();
            out_.put("</blockquote>\n");
            break;
        case NodeKind.list:
            cr();
            if (!n.ordered)
                out_.put("<ul>\n");
            else if (n.start == 1)
                out_.put("<ol>\n");
            else
            {
                out_.put("<ol start=\"");
                out_.put(n.start.to!string);
                out_.put("\">\n");
            }
            renderChildren(n);
            cr();
            out_.put(n.ordered ? "</ol>\n" : "</ul>\n");
            break;
        case NodeKind.item:
            cr();
            out_.put("<li>");
            renderChildren(n);
            out_.put("</li>\n");
            break;
        case NodeKind.paragraph:
            if (n.parent !is null && n.parent.kind == NodeKind.item
                    && n.parent.parent !is null && n.parent.parent.tight)
            {
                renderChildren(n);
            }
            else
            {
                cr();
                out_.put("<p>");
                renderChildren(n);
                out_.put("</p>\n");
            }
            break;
        case NodeKind.heading:
            cr();
            out_.put("<h");
            out_.put(cast(char)('0' + n.level));
            out_.put('>');
            renderChildren(n);
            out_.put("</h");
            out_.put(cast(char)('0' + n.level));
            out_.put(">\n");
            break;
        case NodeKind.thematicBreak:
            cr();
            out_.put("<hr />\n");
            break;
        case NodeKind.codeBlock:
            cr();
            if (n.info.length == 0)
                out_.put("<pre><code>");
            else
            {
                size_t e = 0;
                while (e < n.info.length && !isAsciiWs(n.info[e]))
                    ++e;
                auto lang = n.info[0 .. e];
                out_.put("<pre><code class=\"");
                if (lang.length < 9 || lang[0 .. 9] != "language-")
                    out_.put("language-");
                escapeHtml(out_, lang);
                out_.put("\">");
            }
            escapeHtml(out_, n.content);
            out_.put("</code></pre>\n");
            break;
        case NodeKind.text:
            escapeHtml(out_, n.literal);
            break;
        case NodeKind.softBreak:
            out_.put('\n');
            break;
        case NodeKind.lineBreak:
            out_.put("<br />\n");
            break;
        case NodeKind.code:
            out_.put("<code>");
            escapeHtml(out_, n.literal);
            out_.put("</code>");
            break;
        case NodeKind.emph:
            out_.put("<em>");
            renderChildren(n);
            out_.put("</em>");
            break;
        case NodeKind.strong:
            out_.put("<strong>");
            renderChildren(n);
            out_.put("</strong>");
            break;
        case NodeKind.link:
            out_.put("<a href=\"");
            putHref(out_, n.url);
            out_.put('"');
            if (n.hasTitle)
            {
                out_.put(" title=\"");
                escapeHtml(out_, n.title);
                out_.put('"');
            }
            out_.put('>');
            renderChildren(n);
            out_.put("</a>");
            break;
        case NodeKind.image:
            out_.put("<img src=\"");
            putHref(out_, n.url);
            out_.put("\" alt=\"");
            renderPlain(n);
            out_.put('"');
            if (n.hasTitle)
            {
                out_.put(" title=\"");
                escapeHtml(out_, n.title);
                out_.put('"');
            }
            out_.put(" />");
            break;
        }
    }

    /// The plain-text content of an image's descendants (its alt text).
    void renderPlain(Node n)
    {
        for (Node c = n.firstChild; c !is null; c = c.next)
        {
            switch (c.kind)
            {
            case NodeKind.text:
            case NodeKind.code:
                escapeHtml(out_, c.literal);
                break;
            case NodeKind.softBreak:
            case NodeKind.lineBreak:
                out_.put(' ');
                break;
            default:
                renderPlain(c);
                break;
            }
        }
    }
}
