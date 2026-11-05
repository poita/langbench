/// Rendering of the block tree (with inlines parsed on the fly) to HTML.
module commonmark.html;

import commonmark.ast;
import commonmark.buffer;
import commonmark.chars;
import commonmark.inlines;

private immutable ubyte[256] escapeKind = () {
    ubyte[256] t;
    t['&'] = 1;
    t['<'] = 2;
    t['>'] = 3;
    t['"'] = 4;
    return t;
}();

private immutable string[5] escapeText = ["", "&amp;", "&lt;", "&gt;", "&quot;"];

/// Append `s` with `&`, `<`, `>` and `"` replaced by entities.
void escapeHtml(ref Buffer o, const(char)[] s) pure nothrow
{
    size_t start = 0;
    foreach (i, c; s)
    {
        immutable k = escapeKind[c];
        if (k)
        {
            o.put(s[start .. i]);
            o.put(escapeText[k]);
            start = i + 1;
        }
    }
    o.put(s[start .. $]);
}

private immutable ubyte[256] hrefSafe = () {
    ubyte[256] t;
    foreach (c; "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        ~ "-_.~!#$%()*+,/:;=?@")
        t[c] = 1;
    return t;
}();

private bool startsWithIgnoreCase(const(char)[] s, string prefix) pure nothrow @nogc
{
    if (s.length < prefix.length)
        return false;
    foreach (i, p; prefix)
    {
        char c = s[i];
        if (c >= 'A' && c <= 'Z')
            c += 32;
        if (c != p)
            return false;
    }
    return true;
}

/// Append a destination as an `href`/`src` attribute value: unsafe schemes
/// give an empty value, other bytes are percent-encoded as needed.
void escapeHref(ref Buffer o, const(char)[] s) pure nothrow
{
    if (startsWithIgnoreCase(s, "javascript:") || startsWithIgnoreCase(s, "vbscript:")
        || startsWithIgnoreCase(s, "file:") || startsWithIgnoreCase(s, "data:"))
    {
        if (!(startsWithIgnoreCase(s, "data:image/png") || startsWithIgnoreCase(s, "data:image/gif")
            || startsWithIgnoreCase(s, "data:image/jpeg") || startsWithIgnoreCase(s, "data:image/webp")))
            return;
    }
    static immutable hex = "0123456789ABCDEF";
    size_t start = 0;
    foreach (i, c; s)
    {
        if (hrefSafe[c])
            continue;
        o.put(s[start .. i]);
        start = i + 1;
        if (c == '&')
            o.put("&amp;");
        else if (c == '\'')
            o.put("&#x27;");
        else
        {
            o.put('%');
            o.put(hex[c >> 4]);
            o.put(hex[c & 15]);
        }
    }
    o.put(s[start .. $]);
}

/// Render a parsed document to HTML, appending to `o`.
void renderDocument(ref const Document doc, ref Buffer o)
{
    auto r = Renderer(&doc, &o);
    r.renderChildren(0);
}

private struct Renderer
{
    const(Document)* doc;
    Buffer* o;
    size_t base; // length of the output before rendering started
    InlineParser ip;

    this(const(Document)* d, Buffer* out_)
    {
        doc = d;
        o = out_;
        base = out_.length;
    }

    void cr()
    {
        if (o.length > base && o.back != '\n')
            o.put('\n');
    }

    void renderChildren(int b)
    {
        for (int c = doc.blocks[b].firstChild; c; c = doc.blocks[c].next)
            renderBlock(c);
    }

    void renderBlock(int b)
    {
        const blk = &doc.blocks[b];
        final switch (blk.kind)
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
            if (!blk.ordered)
                o.put("<ul>\n");
            else if (blk.start == 1)
                o.put("<ol>\n");
            else
            {
                o.put("<ol start=\"");
                o.putDecimal(blk.start);
                o.put("\">\n");
            }
            renderChildren(b);
            o.put(blk.ordered ? "</ol>\n" : "</ul>\n");
            break;
        case BlockKind.item:
            cr();
            o.put("<li>");
            renderChildren(b);
            o.put("</li>\n");
            break;
        case BlockKind.paragraph:
        {
            immutable par = blk.parent;
            immutable tight = doc.blocks[par].kind == BlockKind.item
                && doc.blocks[doc.blocks[par].parent].tight;
            if (tight)
                renderInlines(blk.content);
            else
            {
                cr();
                o.put("<p>");
                renderInlines(blk.content);
                o.put("</p>\n");
            }
            break;
        }
        case BlockKind.heading:
            cr();
            o.put("<h");
            o.put(cast(char)('0' + blk.level));
            o.put('>');
            renderInlines(blk.content);
            o.put("</h");
            o.put(cast(char)('0' + blk.level));
            o.put(">\n");
            break;
        case BlockKind.thematicBreak:
            cr();
            o.put("<hr />\n");
            break;
        case BlockKind.indentedCode:
        case BlockKind.fencedCode:
            cr();
            o.put("<pre><code");
            if (blk.kind == BlockKind.fencedCode && blk.info.length)
            {
                size_t e = 0;
                while (e < blk.info.length && !isWhitespace(blk.info[e]))
                    ++e;
                auto lang = blk.info[0 .. e];
                o.put(" class=\"");
                if (!(lang.length >= 9 && lang[0 .. 9] == "language-"))
                    o.put("language-");
                escapeHtml(*o, lang);
                o.put('"');
            }
            o.put('>');
            escapeHtml(*o, blk.content);
            o.put("</code></pre>\n");
            break;
        }
    }

    void renderInlines(const(char)[] content)
    {
        ip.parse(content);
        int cur = InlineParser.root;
        bool entering = true;
        int imageDepth = 0;
        for (;;)
        {
            const nd = &ip.node(cur);
            if (entering)
            {
                if (cur != InlineParser.root)
                    enter(cur, imageDepth);
                if (nd.firstChild)
                {
                    cur = nd.firstChild;
                    continue;
                }
            }
            if (cur == InlineParser.root)
                break;
            leave(cur, imageDepth);
            if (nd.next)
            {
                cur = nd.next;
                entering = true;
            }
            else
            {
                cur = nd.parent;
                entering = false;
            }
        }
    }

    void enter(int i, ref int imageDepth)
    {
        const nd = &ip.node(i);
        final switch (nd.kind)
        {
        case InlineKind.root:
            break;
        case InlineKind.text:
            escapeHtml(*o, ip.textOf(i));
            break;
        case InlineKind.softBreak:
            o.put(imageDepth ? ' ' : '\n');
            break;
        case InlineKind.hardBreak:
            if (imageDepth)
                o.put(' ');
            else
                o.put("<br />\n");
            break;
        case InlineKind.code:
            if (imageDepth)
                escapeHtml(*o, ip.textOf(i));
            else
            {
                o.put("<code>");
                escapeHtml(*o, ip.textOf(i));
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
                escapeHref(*o, ip.destOf(i));
                o.put('"');
                if (nd.hasTitle)
                {
                    o.put(" title=\"");
                    escapeHtml(*o, ip.titleOf(i));
                    o.put('"');
                }
                o.put('>');
            }
            break;
        case InlineKind.image:
            if (!imageDepth)
            {
                o.put("<img src=\"");
                escapeHref(*o, ip.destOf(i));
                o.put("\" alt=\"");
            }
            ++imageDepth;
            break;
        }
    }

    void leave(int i, ref int imageDepth)
    {
        const nd = &ip.node(i);
        switch (nd.kind)
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
            --imageDepth;
            if (!imageDepth)
            {
                o.put('"');
                if (nd.hasTitle)
                {
                    o.put(" title=\"");
                    escapeHtml(*o, ip.titleOf(i));
                    o.put('"');
                }
                o.put(" />");
            }
            break;
        default:
            break;
        }
    }
}
