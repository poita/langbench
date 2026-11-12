/**
 * Renders the block tree (with parsed inlines) to HTML, byte for byte as the
 * CommonMark reference implementation does.
 */
module sitegen.markdown.html;

import std.array : Appender;
import sitegen.markdown.ast;
import sitegen.markdown.entities;
import sitegen.markdown.inlines;

/// Renders `doc` to HTML, parsing the inline content of its leaf blocks.
string renderHtml(Block doc)
{
    auto r = HtmlRenderer();
    r.renderBlock(doc);
    return r.out_.data;
}

private struct HtmlRenderer
{
    Appender!string out_;

    /// Outputs a newline unless the output is empty or ends with one.
    void cr()
    {
        const d = out_.data;
        if (d.length && d[$ - 1] != '\n') out_.put('\n');
    }

    void renderBlock(Block b)
    {
        final switch (b.kind)
        {
            case BlockKind.document:
                foreach (c; b.children) renderBlock(c);
                break;
            case BlockKind.blockQuote:
                cr();
                out_.put("<blockquote>\n");
                foreach (c; b.children) renderBlock(c);
                cr();
                out_.put("</blockquote>\n");
                break;
            case BlockKind.list:
                cr();
                if (!b.ordered)
                    out_.put("<ul>\n");
                else if (b.start == 1)
                    out_.put("<ol>\n");
                else
                {
                    import std.conv : to;

                    out_.put("<ol start=\"");
                    out_.put(b.start.to!string);
                    out_.put("\">\n");
                }
                foreach (c; b.children) renderBlock(c);
                out_.put(b.ordered ? "</ol>\n" : "</ul>\n");
                break;
            case BlockKind.item:
                cr();
                out_.put("<li>");
                foreach (c; b.children) renderBlock(c);
                out_.put("</li>\n");
                break;
            case BlockKind.paragraph:
                {
                    const tight = b.parent !is null && b.parent.kind == BlockKind.item
                        && b.parent.parent !is null && b.parent.parent.tight;
                    if (tight)
                        renderInlines(inlinesOf(b));
                    else
                    {
                        cr();
                        out_.put("<p>");
                        renderInlines(inlinesOf(b));
                        out_.put("</p>\n");
                    }
                }
                break;
            case BlockKind.heading:
                cr();
                out_.put("<h");
                out_.put(cast(char)('0' + b.level));
                out_.put('>');
                renderInlines(inlinesOf(b));
                out_.put("</h");
                out_.put(cast(char)('0' + b.level));
                out_.put(">\n");
                break;
            case BlockKind.thematicBreak:
                cr();
                out_.put("<hr />\n");
                break;
            case BlockKind.codeBlock:
                cr();
                if (b.info.length == 0)
                    out_.put("<pre><code>");
                else
                {
                    size_t e = 0;
                    while (e < b.info.length && !isSpace(b.info[e])) e++;
                    const word = b.info[0 .. e];
                    out_.put("<pre><code class=\"");
                    if (word.length < 9 || word[0 .. 9] != "language-") out_.put("language-");
                    escapeHtml(out_, word);
                    out_.put("\">");
                }
                escapeHtml(out_, cast(string) b.content.data);
                out_.put("</code></pre>\n");
                break;
        }
    }

    static Inline inlinesOf(Block b)
    {
        if (b.inlines is null)
        {
            auto text = cast(string) b.content.data;
            b.inlines = parseInlines(trimEnd(text));
        }
        return b.inlines;
    }

    static string trimEnd(string s)
    {
        size_t e = s.length;
        while (e > 0 && isSpace(s[e - 1])) e--;
        return s[0 .. e];
    }

    /// Renders an inline list without recursion.
    void renderInlines(Inline first)
    {
        Inline[] stack;
        Inline cur = first;
        while (cur !is null)
        {
            // Enter `cur`.
            bool descend = false;
            final switch (cur.kind)
            {
                case InlineKind.text:
                    escapeHtml(out_, cur.text);
                    break;
                case InlineKind.softbreak:
                    out_.put('\n');
                    break;
                case InlineKind.linebreak:
                    out_.put("<br />\n");
                    break;
                case InlineKind.code:
                    out_.put("<code>");
                    escapeHtml(out_, cur.text);
                    out_.put("</code>");
                    break;
                case InlineKind.emph:
                    out_.put("<em>");
                    descend = true;
                    break;
                case InlineKind.strong:
                    out_.put("<strong>");
                    descend = true;
                    break;
                case InlineKind.link:
                    out_.put("<a href=\"");
                    encodeHref(out_, cur.dest);
                    out_.put('"');
                    if (cur.hasTitle)
                    {
                        out_.put(" title=\"");
                        escapeHtml(out_, cur.title);
                        out_.put('"');
                    }
                    out_.put('>');
                    descend = true;
                    break;
                case InlineKind.image:
                    out_.put("<img src=\"");
                    encodeHref(out_, cur.dest);
                    out_.put("\" alt=\"");
                    renderAlt(cur.firstChild);
                    out_.put('"');
                    if (cur.hasTitle)
                    {
                        out_.put(" title=\"");
                        escapeHtml(out_, cur.title);
                        out_.put('"');
                    }
                    out_.put(" />");
                    break;
            }
            if (descend && cur.firstChild !is null)
            {
                stack ~= cur;
                cur = cur.firstChild;
                continue;
            }
            if (descend) exitNode(cur);
            // Move to the next node, leaving finished containers.
            while (cur.next is null && stack.length)
            {
                cur = stack[$ - 1];
                stack.length = stack.length - 1;
                exitNode(cur);
            }
            cur = cur.next;
        }
    }

    void exitNode(Inline n)
    {
        switch (n.kind)
        {
            case InlineKind.emph: out_.put("</em>"); break;
            case InlineKind.strong: out_.put("</strong>"); break;
            case InlineKind.link: out_.put("</a>"); break;
            default: break;
        }
    }

    /// The plain text of an image's descendants.
    void renderAlt(Inline first)
    {
        Inline[] stack;
        Inline cur = first;
        while (cur !is null)
        {
            switch (cur.kind)
            {
                case InlineKind.text, InlineKind.code:
                    escapeHtml(out_, cur.text);
                    break;
                case InlineKind.softbreak, InlineKind.linebreak:
                    out_.put(' ');
                    break;
                default:
                    break;
            }
            if (cur.firstChild !is null)
            {
                stack ~= cur;
                cur = cur.firstChild;
                continue;
            }
            while (cur.next is null && stack.length)
            {
                cur = stack[$ - 1];
                stack.length = stack.length - 1;
            }
            cur = cur.next;
        }
    }
}
