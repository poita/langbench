/**
 * Phase 2 of the Markdown converter: inline structure.
 *
 * The raw text of a paragraph or heading is parsed left to right into a
 * list of $(REF Inline, sitegen,markdown,ast) nodes, using a delimiter stack
 * for emphasis and a bracket stack for links and images, as in the
 * CommonMark reference implementation.
 */
module sitegen.markdown.inlines;

import sitegen.markdown.ast;
import sitegen.markdown.entities;

/**
 * Parses the inline content of one paragraph or heading.
 *
 * Params:
 *   content = the raw text, without trailing whitespace
 * Returns: the first node of the inline list, or `null` if there is none.
 */
Inline parseInlines(string content)
{
    auto p = new InlineParser(content);
    return p.parse();
}

private final class Delim
{
    Delim prev, next;
    Inline node;
    char ch;
    int origLen;
    bool canOpen, canClose;
    size_t position;
}

private final class Bracket
{
    Bracket prev;
    Inline node;
    bool image;
    size_t position;
}

private final class InlineParser
{
    string s;
    size_t pos;
    Inline head, tail;
    Delim delimTop;
    Bracket brackets;
    bool linkClosed = true;

    // cmark's backtick memo: last[k] is the start of the last run of k
    // backticks seen by a scan.
    size_t[] backtickLast;
    bool backticksScanned;

    this(string s)
    {
        this.s = s;
        backtickLast = new size_t[8];
    }

    Inline parse()
    {
        const n = s.length;
        while (pos < n)
        {
            switch (s[pos])
            {
                case '\n':
                    handleNewline();
                    break;
                case '`':
                    handleBackticks();
                    break;
                case '\\':
                    handleBackslash();
                    break;
                case '&':
                    handleEntity();
                    break;
                case '<':
                    handleLessThan();
                    break;
                case '*', '_':
                    handleDelimiterRun();
                    break;
                case '[':
                    pos++;
                    pushBracket(addText("["), false);
                    linkClosed = false;
                    break;
                case '!':
                    if (pos + 1 < n && s[pos + 1] == '[')
                    {
                        pos += 2;
                        pushBracket(addText("!["), true);
                    }
                    else
                    {
                        pos++;
                        addText("!");
                    }
                    break;
                case ']':
                    handleCloseBracket();
                    break;
                default:
                    handleTextRun();
            }
        }
        processEmphasis(0);
        return head;
    }

    // ------------------------------------------------------------------
    // Node list helpers
    // ------------------------------------------------------------------

    Inline append(Inline node)
    {
        node.prev = tail;
        node.next = null;
        if (tail !is null)
            tail.next = node;
        else
            head = node;
        tail = node;
        return node;
    }

    Inline addText(string t)
    {
        return append(new Inline(InlineKind.text, t));
    }

    void unlink(Inline node)
    {
        if (node.prev !is null)
            node.prev.next = node.next;
        else
            head = node.next;
        if (node.next !is null)
            node.next.prev = node.prev;
        else
            tail = node.prev;
        node.prev = node.next = null;
    }

    void pushBracket(Inline node, bool image)
    {
        auto b = new Bracket;
        b.prev = brackets;
        b.node = node;
        b.image = image;
        b.position = pos;
        brackets = b;
    }

    // ------------------------------------------------------------------
    // Simple constructs
    // ------------------------------------------------------------------

    static bool isSpecial(char c) pure nothrow @nogc
    {
        switch (c)
        {
            case '\n', '`', '\\', '&', '<', '*', '_', '[', ']', '!':
                return true;
            default:
                return false;
        }
    }

    void handleTextRun()
    {
        const start = pos;
        const n = s.length;
        pos++;
        while (pos < n && !isSpecial(s[pos])) pos++;
        size_t end = pos;
        if (pos < n && s[pos] == '\n')
            while (end > start && isSpace(s[end - 1])) end--;
        if (end > start) addText(s[start .. end]);
    }

    void handleNewline()
    {
        const hard = pos >= 2 && s[pos - 1] == ' ' && s[pos - 2] == ' ';
        append(new Inline(hard ? InlineKind.linebreak : InlineKind.softbreak));
        pos++;
        while (pos < s.length && isSpaceOrTab(s[pos])) pos++;
    }

    void handleBackslash()
    {
        const n = s.length;
        if (pos + 1 < n && isAsciiPunct(s[pos + 1]))
        {
            addText(s[pos + 1 .. pos + 2]);
            pos += 2;
        }
        else if (pos + 1 < n && s[pos + 1] == '\n')
        {
            append(new Inline(InlineKind.linebreak));
            pos += 2;
        }
        else
        {
            addText("\\");
            pos++;
        }
    }

    void handleEntity()
    {
        string decoded;
        size_t end;
        if (matchEntity(s, pos + 1, decoded, end))
        {
            addText(decoded);
            pos = end;
        }
        else
        {
            addText("&");
            pos++;
        }
    }

    void handleBackticks()
    {
        const n = s.length;
        size_t runEnd = pos;
        while (runEnd < n && s[runEnd] == '`') runEnd++;
        const len = runEnd - pos;
        const closeAt = findClosingBackticks(runEnd, len);
        if (closeAt < 0)
        {
            addText(s[pos .. runEnd]);
            pos = runEnd;
            return;
        }
        auto raw = s[runEnd .. closeAt];
        auto buf = raw.dup;
        foreach (ref c; buf)
            if (c == '\n') c = ' ';
        string content = cast(string) buf;
        if (content.length >= 2 && content[0] == ' ' && content[$ - 1] == ' ')
        {
            foreach (c; content)
                if (c != ' ')
                {
                    content = content[1 .. $ - 1];
                    break;
                }
        }
        append(new Inline(InlineKind.code, content));
        pos = closeAt + len;
    }

    /// Finds a run of exactly `len` backticks starting at or after `from`,
    /// using the backtick memo.  Returns its start, or -1.
    ptrdiff_t findClosingBackticks(size_t from, size_t len)
    {
        if (len >= backtickLast.length) backtickLast.length = len + 1;
        if (backticksScanned && backtickLast[len] <= from) return -1;
        const n = s.length;
        size_t i = from;
        while (i < n)
        {
            if (s[i] != '`')
            {
                i++;
                continue;
            }
            const start = i;
            while (i < n && s[i] == '`') i++;
            const k = i - start;
            if (k >= backtickLast.length) backtickLast.length = k + 1;
            backtickLast[k] = start;
            if (k == len) return start;
        }
        backticksScanned = true;
        return -1;
    }

    // ------------------------------------------------------------------
    // Autolinks
    // ------------------------------------------------------------------

    void handleLessThan()
    {
        const end = scanAutolink(pos + 1);
        if (end == 0)
        {
            addText("<");
            pos++;
            return;
        }
        // s[end - 1] is the closing '>'.
        const inner = s[pos + 1 .. end - 1];
        const isEmail = scanUriAutolink(pos + 1) == 0;
        const text = decodeEntities(inner);
        auto link = new Inline(InlineKind.link);
        link.dest = isEmail ? "mailto:" ~ text : text;
        auto child = new Inline(InlineKind.text, text);
        link.firstChild = link.lastChild = child;
        append(link);
        pos = end;
    }

    /// Returns the index after the closing `>` of an autolink whose text
    /// starts at `start`, or 0.
    size_t scanAutolink(size_t start) const
    {
        const e = scanUriAutolink(start);
        if (e) return e;
        return scanEmailAutolink(start);
    }

    size_t scanUriAutolink(size_t start) const
    {
        const n = s.length;
        size_t i = start;
        if (i >= n || !isAlpha(s[i])) return 0;
        i++;
        size_t count = 0;
        while (i < n && count < 32 && (isAlnum(s[i]) || s[i] == '.' || s[i] == '+' || s[i] == '-'))
        {
            i++;
            count++;
        }
        if (count < 1 || count > 31) return 0;
        if (i >= n || s[i] != ':') return 0;
        i++;
        while (i < n && cast(ubyte) s[i] > 0x20 && s[i] != '<' && s[i] != '>') i++;
        if (i < n && s[i] == '>') return i + 1;
        return 0;
    }

    size_t scanEmailAutolink(size_t start) const
    {
        const n = s.length;
        size_t i = start;
        static bool localChar(char c) pure nothrow @nogc
        {
            if (isAlnum(c)) return true;
            switch (c)
            {
                case '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`',
                    '{', '|', '}', '~', '-':
                    return true;
                default:
                    return false;
            }
        }
        while (i < n && localChar(s[i])) i++;
        if (i == start || i >= n || s[i] != '@') return 0;
        i++;
        while (true)
        {
            const labelStart = i;
            while (i < n && (isAlnum(s[i]) || s[i] == '-')) i++;
            const len = i - labelStart;
            if (len == 0 || len > 63) return 0;
            if (!isAlnum(s[labelStart]) || !isAlnum(s[i - 1])) return 0;
            if (i < n && s[i] == '.')
            {
                i++;
                continue;
            }
            break;
        }
        if (i < n && s[i] == '>') return i + 1;
        return 0;
    }

    // ------------------------------------------------------------------
    // Emphasis
    // ------------------------------------------------------------------

    void handleDelimiterRun()
    {
        const n = s.length;
        const ch = s[pos];
        size_t end = pos;
        while (end < n && s[end] == ch) end++;
        const len = end - pos;
        const before = pos == 0 ? '\n' : s[pos - 1];
        const after = end >= n ? '\n' : s[end];
        const beforeSpace = isSpace(before);
        const afterSpace = isSpace(after);
        const beforePunct = isAsciiPunct(before);
        const afterPunct = isAsciiPunct(after);
        const leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct);
        const rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct);
        bool canOpen, canClose;
        if (ch == '*')
        {
            canOpen = leftFlanking;
            canClose = rightFlanking;
        }
        else
        {
            canOpen = leftFlanking && (!rightFlanking || beforePunct);
            canClose = rightFlanking && (!leftFlanking || afterPunct);
        }
        auto node = addText(s[pos .. end]);
        pos = end;
        if (canOpen || canClose)
        {
            auto d = new Delim;
            d.node = node;
            d.ch = ch;
            d.origLen = cast(int) len;
            d.canOpen = canOpen;
            d.canClose = canClose;
            d.position = pos;
            d.prev = delimTop;
            if (delimTop !is null) delimTop.next = d;
            delimTop = d;
        }
    }

    void removeDelim(Delim d)
    {
        if (d.next !is null)
            d.next.prev = d.prev;
        else
            delimTop = d.prev;
        if (d.prev !is null) d.prev.next = d.next;
        d.prev = d.next = null;
    }

    void processEmphasis(size_t stackBottom)
    {
        size_t[12] openersBottom = stackBottom;

        // The first entry with position >= stackBottom.
        Delim closer = delimTop;
        while (closer !is null && closer.prev !is null && closer.prev.position >= stackBottom)
            closer = closer.prev;
        if (closer !is null && closer.position < stackBottom) closer = null;

        while (closer !is null)
        {
            if (!closer.canClose)
            {
                closer = closer.next;
                continue;
            }
            const kind = (closer.ch == '*' ? 0 : 6) + (closer.canOpen ? 3 : 0) + closer.origLen % 3;
            Delim opener = closer.prev;
            bool found = false;
            while (opener !is null && opener.position >= openersBottom[kind])
            {
                if (opener.canOpen && opener.ch == closer.ch)
                {
                    const oddMatch = (closer.canOpen || opener.canClose)
                        && closer.origLen % 3 != 0
                        && (opener.origLen + closer.origLen) % 3 == 0;
                    if (!oddMatch)
                    {
                        found = true;
                        break;
                    }
                }
                opener = opener.prev;
            }
            if (!found)
            {
                openersBottom[kind] = closer.position;
                auto next = closer.next;
                if (!closer.canOpen) removeDelim(closer);
                closer = next;
                continue;
            }

            auto openNode = opener.node;
            auto closeNode = closer.node;
            const use = (openNode.text.length >= 2 && closeNode.text.length >= 2) ? 2 : 1;
            openNode.text = openNode.text[0 .. $ - use];
            closeNode.text = closeNode.text[use .. $];

            // Remove the delimiters between opener and closer.
            for (Delim d = closer.prev; d !is opener;)
            {
                auto p = d.prev;
                removeDelim(d);
                d = p;
            }

            // Wrap the nodes between the two text nodes.
            auto em = new Inline(use == 2 ? InlineKind.strong : InlineKind.emph);
            auto first = openNode.next;
            if (first !is closeNode)
            {
                auto last = closeNode.prev;
                em.firstChild = first;
                em.lastChild = last;
                first.prev = null;
                last.next = null;
            }
            openNode.next = em;
            em.prev = openNode;
            em.next = closeNode;
            closeNode.prev = em;

            if (openNode.text.length == 0)
            {
                unlink(openNode);
                removeDelim(opener);
            }
            if (closeNode.text.length == 0)
            {
                unlink(closeNode);
                auto next = closer.next;
                removeDelim(closer);
                closer = next;
            }
        }

        while (delimTop !is null && delimTop.position >= stackBottom)
        {
            auto d = delimTop;
            delimTop = d.prev;
            d.prev = null;
            if (delimTop !is null) delimTop.next = null;
        }
    }

    // ------------------------------------------------------------------
    // Links and images
    // ------------------------------------------------------------------

    void handleCloseBracket()
    {
        pos++; // past the ']'
        if (brackets is null)
        {
            addText("]");
            return;
        }
        auto opener = brackets;
        if (!opener.image && linkClosed)
        {
            brackets = opener.prev;
            addText("]");
            return;
        }
        string dest, title;
        bool hasTitle;
        size_t endPos;
        if (!parseLinkTail(pos, dest, title, hasTitle, endPos))
        {
            brackets = opener.prev;
            addText("]");
            return;
        }

        // Process emphasis inside the brackets first; the nodes are still
        // siblings in the top-level list, which is all it needs.
        processEmphasis(opener.position);

        auto node = new Inline(opener.image ? InlineKind.image : InlineKind.link);
        node.dest = dest;
        node.title = title;
        node.hasTitle = hasTitle;
        auto first = opener.node.next;
        if (first !is null)
        {
            node.firstChild = first;
            node.lastChild = tail;
            first.prev = null;
        }
        auto before = opener.node.prev;
        node.prev = before;
        if (before !is null)
            before.next = node;
        else
            head = node;
        node.next = null;
        tail = node;

        brackets = opener.prev;
        if (!opener.image) linkClosed = true;
        pos = endPos;
    }

    size_t skipWhitespace(size_t p) const
    {
        while (p < s.length && isSpace(s[p])) p++;
        return p;
    }

    /// Parses `(destination "title")` starting at `p`, just after a `]`.
    bool parseLinkTail(size_t p, out string dest, out string title, out bool hasTitle,
        out size_t endPos)
    {
        const n = s.length;
        if (p >= n || s[p] != '(') return false;
        p = skipWhitespace(p + 1);

        // Destination.
        size_t destStart, destEnd, i;
        if (p < n && s[p] == '<')
        {
            i = p + 1;
            bool closed = false;
            while (i < n)
            {
                const c = s[i];
                if (c == '>')
                {
                    i++;
                    closed = true;
                    break;
                }
                else if (c == '\\')
                    i += 2;
                else if (c == '\n' || c == '<')
                    return false;
                else
                    i++;
            }
            if (!closed || i >= n) return false;
            destStart = p + 1;
            destEnd = i - 1;
        }
        else
        {
            i = p;
            int depth = 0;
            while (i < n)
            {
                const c = s[i];
                if (c == '\\' && i + 1 < n && isAsciiPunct(s[i + 1]))
                    i += 2;
                else if (c == '(')
                {
                    depth++;
                    i++;
                    if (depth > 32) return false;
                }
                else if (c == ')')
                {
                    if (depth == 0) break;
                    depth--;
                    i++;
                }
                else if (isSpace(c))
                    break;
                else
                    i++;
            }
            if (i >= n || depth != 0) return false;
            destStart = p;
            destEnd = i;
        }
        const rawDest = trimAscii(s[destStart .. destEnd]);

        // Optional title.
        size_t q = skipWhitespace(i);
        string rawTitle;
        if (q > i && q < n && (s[q] == '"' || s[q] == '\'' || s[q] == '('))
        {
            size_t titleEnd;
            if (scanTitle(q, titleEnd))
            {
                hasTitle = true;
                rawTitle = s[q + 1 .. titleEnd - 1];
                q = skipWhitespace(titleEnd);
            }
        }
        if (q >= n || s[q] != ')') return false;

        dest = unescapeBackslashes(decodeEntities(rawDest));
        if (hasTitle) title = unescapeBackslashes(decodeEntities(rawTitle));
        endPos = q + 1;
        return true;
    }

    /// Scans the longest title starting at the quote at `start`.  `end` is
    /// the index after its closing delimiter.
    bool scanTitle(size_t start, out size_t end) const
    {
        const open = s[start];
        const close = open == '(' ? ')' : open;
        const n = s.length;
        ptrdiff_t lastEscaped = -1;
        for (size_t i = start + 1; i < n; i++)
        {
            const c = s[i];
            const escaped = s[i - 1] == '\\';
            if (c == close)
            {
                if (!escaped)
                {
                    end = i + 1;
                    return true;
                }
                lastEscaped = cast(ptrdiff_t) i;
            }
            else if (open == '(' && c == '(' && !escaped)
                break;
        }
        if (lastEscaped >= 0)
        {
            end = lastEscaped + 1;
            return true;
        }
        return false;
    }
}

unittest
{
    string render(Inline n)
    {
        string r;
        for (; n !is null; n = n.next)
        {
            final switch (n.kind)
            {
                case InlineKind.text: r ~= n.text; break;
                case InlineKind.softbreak: r ~= "/"; break;
                case InlineKind.linebreak: r ~= "\\\\"; break;
                case InlineKind.code: r ~= "`" ~ n.text ~ "`"; break;
                case InlineKind.emph: r ~= "<em>" ~ render(n.firstChild) ~ "</em>"; break;
                case InlineKind.strong: r ~= "<strong>" ~ render(n.firstChild) ~ "</strong>"; break;
                case InlineKind.link: r ~= "<a " ~ n.dest ~ ">" ~ render(n.firstChild) ~ "</a>"; break;
                case InlineKind.image: r ~= "<img " ~ n.dest ~ ">" ~ render(n.firstChild) ~ "</img>"; break;
            }
        }
        return r;
    }

    assert(render(parseInlines("*foo**bar**baz*")) == "<em>foo<strong>bar</strong>baz</em>");
    assert(render(parseInlines("_a_b_")) == "<em>a_b</em>");
    assert(render(parseInlines("a [b *c*](/u \"t\") d")) == "a <a /u>b <em>c</em></a> d");
    assert(render(parseInlines("``a ` b``")) == "`a ` b`");
    assert(render(parseInlines("[x [a](/b) ![i](/j) y](/d)")) == "[x <a /b>a</a> <img /j>i</img> y](/d)");
    assert(render(parseInlines("<http://a.b/?x=1&y=2>")) == "<a http://a.b/?x=1&y=2>http://a.b/?x=1&y=2</a>");
    assert(render(parseInlines("<me@x.org>")) == "<a mailto:me@x.org>me@x.org</a>");
    assert(render(parseInlines("a  \nb\nc")) == "a\\\\b/c");
}
