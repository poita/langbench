/// Phase 2 of the Markdown conversion: inline parsing with a delimiter stack
/// and a bracket stack.
module sitegen.markdown.inlines;

import sitegen.markdown.node;
import sitegen.markdown.text;
import std.array : Appender, appender;

private final class Delim
{
    Delim prev, next;
    Node node;
    char ch;
    int origLen;
    bool canOpen, canClose;
    int position;
}

private struct Bracket
{
    Node node;
    bool image;
    int position;
}

/// Parses the content of paragraphs and headings into inline nodes.
///
/// One instance may be reused for many blocks.
final class InlineParser
{
    private string s;
    private int pos;
    private Node block;
    private Delim lastDelim;
    private Bracket[] bracketStack;
    private size_t bracketCount;
    private bool linkClosed;
    private int[102] backtickLast;
    private bool backtickScanned;

    /// Parse `content` (the raw text of `blockNode`) and append the resulting
    /// inline nodes as children of `blockNode`.
    void parse(Node blockNode, string content)
    {
        size_t end = content.length;
        while (end > 0 && isAsciiWs(content[end - 1]))
            --end;
        s = content[0 .. end];
        pos = 0;
        block = blockNode;
        lastDelim = null;
        bracketCount = 0;
        linkClosed = true;
        backtickLast[] = 0;
        backtickScanned = false;
        while (pos < s.length)
            parseInline();
        processEmphasis(0);
    }

    // ------------------------------------------------------------------

    private Node addText(string lit)
    {
        auto n = new Node(NodeKind.text);
        n.literal = lit;
        block.appendChild(n);
        return n;
    }

    private void pushBracket(Bracket b) pure nothrow @safe
    {
        if (bracketCount == bracketStack.length)
            bracketStack ~= b;
        else
            bracketStack[bracketCount] = b;
        ++bracketCount;
    }

    private char at(int i) const pure nothrow @safe @nogc
    {
        return i >= 0 && i < s.length ? s[i] : '\0';
    }

    private void parseInline()
    {
        immutable c = s[pos];
        switch (c)
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
        case '*':
        case '_':
            handleDelimiterRun(c);
            break;
        case '[':
            ++pos;
            auto n = addText("[");
            pushBracket(Bracket(n, false, pos));
            linkClosed = false;
            break;
        case '!':
            if (at(pos + 1) == '[')
            {
                pos += 2;
                auto n2 = addText("![");
                pushBracket(Bracket(n2, true, pos));
            }
            else
            {
                ++pos;
                addText("!");
            }
            break;
        case ']':
            handleCloseBracket();
            break;
        default:
            handlePlainText();
            break;
        }
    }

    private static bool isSpecial(char c) pure nothrow @safe @nogc
    {
        switch (c)
        {
        case '\n': case '`': case '\\': case '&': case '<': case '*': case '_':
        case '[': case ']': case '!':
            return true;
        default:
            return false;
        }
    }

    private void handlePlainText()
    {
        int start = pos;
        while (pos < s.length && !isSpecial(s[pos]))
            ++pos;
        int end = pos;
        if (pos < s.length && s[pos] == '\n')
            while (end > start && isAsciiWs(s[end - 1]))
                --end;
        if (end > start)
            addText(s[start .. end]);
    }

    private void handleNewline()
    {
        immutable nlpos = pos;
        ++pos;
        while (pos < s.length && isSpaceOrTab(s[pos]))
            ++pos;
        auto n = new Node(nlpos > 1 && s[nlpos - 1] == ' ' && s[nlpos - 2] == ' '
                ? NodeKind.lineBreak : NodeKind.softBreak);
        block.appendChild(n);
    }

    private void handleBackslash()
    {
        immutable next = at(pos + 1);
        if (pos + 1 < s.length && isAsciiPunct(next))
        {
            addText(s[pos + 1 .. pos + 2]);
            pos += 2;
        }
        else if (pos + 1 < s.length && next == '\n')
        {
            block.appendChild(new Node(NodeKind.lineBreak));
            pos += 2;
        }
        else
        {
            addText("\\");
            ++pos;
        }
    }

    private void handleEntity()
    {
        size_t len;
        dchar cp;
        if (matchEntity(s, pos, len, cp))
        {
            auto o = appender!(char[])();
            putCodePoint(o, cp);
            addText(o.data.idup);
            pos += cast(int) len;
        }
        else
        {
            addText("&");
            ++pos;
        }
    }

    // ------------------------------------------------------------------
    // code spans

    private void handleBackticks()
    {
        int n = 0;
        while (pos + n < s.length && s[pos + n] == '`')
            ++n;
        immutable p = pos + n;
        int closeStart = findBacktickRun(n, p);
        if (closeStart < 0)
        {
            addText(s[pos .. p]);
            pos = p;
            return;
        }
        auto o = appender!(char[])();
        foreach (ch; s[p .. closeStart])
            o.put(ch == '\n' ? ' ' : ch);
        char[] body_ = o.data;
        if (body_.length >= 2 && body_[0] == ' ' && body_[$ - 1] == ' ')
        {
            bool allSpaces = true;
            foreach (ch; body_)
                if (ch != ' ')
                {
                    allSpaces = false;
                    break;
                }
            if (!allSpaces)
                body_ = body_[1 .. $ - 1];
        }
        auto node = new Node(NodeKind.code);
        node.literal = body_.idup;
        block.appendChild(node);
        pos = closeStart + n;
    }

    /// Find the start of the next backtick run of exactly `n` characters at or
    /// after `p`, using cmark's memo of run positions; -1 if there is none.
    private int findBacktickRun(int n, int p)
    {
        if (n > 100)
            return -1;
        if (backtickScanned && backtickLast[n] <= p)
            return -1;
        int i = p;
        while (i < s.length)
        {
            if (s[i] != '`')
            {
                ++i;
                continue;
            }
            immutable start = i;
            while (i < s.length && s[i] == '`')
                ++i;
            immutable k = i - start;
            if (k <= 100)
                backtickLast[k] = start;
            if (k == n)
                return start;
        }
        backtickScanned = true;
        return -1;
    }

    // ------------------------------------------------------------------
    // autolinks

    /// Length of a URI autolink body starting after `<` at `i` (up to and
    /// including the closing `>`), or 0.
    private int scanUriAutolink(int i) const pure nothrow @safe @nogc
    {
        int j = i;
        if (!isAsciiAlpha(at(j)))
            return 0;
        ++j;
        int schemeRest = 0;
        while (j < s.length && (isAsciiAlnum(s[j]) || s[j] == '.' || s[j] == '+' || s[j] == '-'))
        {
            ++j;
            ++schemeRest;
        }
        if (schemeRest < 1 || schemeRest > 31 || at(j) != ':')
            return 0;
        ++j;
        while (j < s.length && s[j] > ' ' && s[j] != '<' && s[j] != '>')
            ++j;
        if (at(j) != '>')
            return 0;
        return j + 1 - i;
    }

    private static bool isEmailLocal(char c) pure nothrow @safe @nogc
    {
        if (isAsciiAlnum(c))
            return true;
        switch (c)
        {
        case '.': case '!': case '#': case '$': case '%': case '&': case '\'':
        case '*': case '+': case '/': case '=': case '?': case '^': case '_':
        case '`': case '{': case '|': case '}': case '~': case '-':
            return true;
        default:
            return false;
        }
    }

    private int scanEmailAutolink(int i) const pure nothrow @safe @nogc
    {
        int j = i;
        while (j < s.length && isEmailLocal(s[j]))
            ++j;
        if (j == i || at(j) != '@')
            return 0;
        ++j;
        while (true)
        {
            immutable labelStart = j;
            while (j < s.length && (isAsciiAlnum(s[j]) || s[j] == '-'))
                ++j;
            immutable len = j - labelStart;
            if (len < 1 || len > 63 || !isAsciiAlnum(s[labelStart]) || !isAsciiAlnum(s[j - 1]))
                return 0;
            if (at(j) == '.')
            {
                ++j;
                continue;
            }
            break;
        }
        if (at(j) != '>')
            return 0;
        return j + 1 - i;
    }

    private void handleLessThan()
    {
        int len = scanUriAutolink(pos + 1);
        bool email = false;
        if (len == 0)
        {
            len = scanEmailAutolink(pos + 1);
            email = len != 0;
        }
        if (len == 0)
        {
            addText("<");
            ++pos;
            return;
        }
        string inner = decodeEntities(s[pos + 1 .. pos + len]);
        auto link = new Node(NodeKind.link);
        link.url = email ? "mailto:" ~ inner : inner;
        auto t = new Node(NodeKind.text);
        t.literal = inner;
        link.appendChild(t);
        block.appendChild(link);
        pos += len + 1;
    }

    // ------------------------------------------------------------------
    // emphasis

    private void handleDelimiterRun(char c)
    {
        int start = pos;
        while (pos < s.length && s[pos] == c)
            ++pos;
        immutable n = pos - start;
        immutable before = start == 0 ? '\n' : s[start - 1];
        immutable after = pos >= s.length ? '\n' : s[pos];
        immutable afterWs = isAsciiWs(after);
        immutable beforeWs = isAsciiWs(before);
        immutable afterPunct = isAsciiPunct(after);
        immutable beforePunct = isAsciiPunct(before);
        immutable leftFlanking = !afterWs && (!afterPunct || beforeWs || beforePunct);
        immutable rightFlanking = !beforeWs && (!beforePunct || afterWs || afterPunct);
        bool canOpen, canClose;
        if (c == '*')
        {
            canOpen = leftFlanking;
            canClose = rightFlanking;
        }
        else
        {
            canOpen = leftFlanking && (!rightFlanking || beforePunct);
            canClose = rightFlanking && (!leftFlanking || afterPunct);
        }
        auto node = addText(s[start .. pos]);
        if (canOpen || canClose)
        {
            auto d = new Delim;
            d.node = node;
            d.ch = c;
            d.origLen = n;
            d.canOpen = canOpen;
            d.canClose = canClose;
            d.position = pos;
            d.prev = lastDelim;
            if (lastDelim !is null)
                lastDelim.next = d;
            lastDelim = d;
        }
    }

    private void removeDelim(Delim d) pure nothrow @safe @nogc
    {
        if (d.prev !is null)
            d.prev.next = d.next;
        if (d.next !is null)
            d.next.prev = d.prev;
        else
            lastDelim = d.prev;
    }

    private void processEmphasis(int stackBottom)
    {
        if (lastDelim is null || lastDelim.position < stackBottom)
            return;
        int[12] openersBottom;
        openersBottom[] = stackBottom;
        Delim closer = lastDelim;
        while (closer.prev !is null && closer.prev.position >= stackBottom)
            closer = closer.prev;

        while (closer !is null)
        {
            if (!closer.canClose)
            {
                closer = closer.next;
                continue;
            }
            immutable kind = (closer.ch == '_' ? 6 : 0) + (closer.canOpen ? 3 : 0) + closer.origLen % 3;
            Delim opener = closer.prev;
            bool found = false;
            while (opener !is null && opener.position >= openersBottom[kind])
            {
                if (opener.canOpen && opener.ch == closer.ch
                        && (!(closer.canOpen || opener.canClose) || closer.origLen % 3 == 0
                            || (opener.origLen + closer.origLen) % 3 != 0))
                {
                    found = true;
                    break;
                }
                opener = opener.prev;
            }
            if (found)
                closer = insertEmphasis(opener, closer);
            else
            {
                openersBottom[kind] = closer.position;
                Delim old = closer;
                closer = closer.next;
                if (!old.canOpen)
                    removeDelim(old);
            }
        }
        while (lastDelim !is null && lastDelim.position >= stackBottom)
            removeDelim(lastDelim);
    }

    private Delim insertEmphasis(Delim opener, Delim closer)
    {
        Node openText = opener.node;
        Node closeText = closer.node;
        immutable use = openText.literal.length >= 2 && closeText.literal.length >= 2 ? 2 : 1;
        openText.literal = openText.literal[0 .. $ - use];
        closeText.literal = closeText.literal[use .. $];

        for (Delim d = closer.prev; d !is null && d !is opener;)
        {
            Delim p = d.prev;
            removeDelim(d);
            d = p;
        }

        auto emph = new Node(use == 2 ? NodeKind.strong : NodeKind.emph);
        for (Node tmp = openText.next; tmp !is null && tmp !is closeText;)
        {
            Node nx = tmp.next;
            tmp.unlink();
            emph.appendChild(tmp);
            tmp = nx;
        }
        emph.insertAfter(openText);

        if (openText.literal.length == 0)
        {
            openText.unlink();
            removeDelim(opener);
        }
        Delim next = closer.next;
        if (closeText.literal.length == 0)
        {
            closeText.unlink();
            removeDelim(closer);
            return next;
        }
        return closer;
    }

    // ------------------------------------------------------------------
    // links and images

    private int skipWs(int i) const pure nothrow @safe @nogc
    {
        while (i < s.length && isAsciiWs(s[i]))
            ++i;
        return i;
    }

    /// Longest title match starting at the opening delimiter `s[i]`: index of
    /// the closing delimiter or -1.
    private int scanTitle(int i) const pure nothrow @safe @nogc
    {
        immutable open = s[i];
        immutable close = open == '(' ? ')' : open;
        int best = -1;
        for (int k = i + 1; k < s.length; ++k)
        {
            immutable c = s[k];
            if (c == close)
            {
                best = k;
                if (s[k - 1] != '\\')
                    break;
            }
            else if (open == '(' && c == '(' && s[k - 1] != '\\')
                break;
        }
        return best;
    }

    private bool parseInlineLink(out string url, out string title, out bool hasTitle, out int endPos)
    {
        int i = pos + 1;
        if (at(i) != '(' || i >= s.length)
            return false;
        i = skipWs(i + 1);
        int destStart, destEnd;
        if (at(i) == '<' && i < s.length)
        {
            int j = i + 1;
            bool found = false;
            while (j < s.length)
            {
                immutable c = s[j];
                if (c == '>')
                {
                    found = true;
                    break;
                }
                if (c == '\\')
                    j += 2;
                else if (c == '\n' || c == '<')
                    break;
                else
                    ++j;
            }
            if (!found)
                return false;
            destStart = i + 1;
            destEnd = j;
            i = j + 1;
        }
        else
        {
            int j = i;
            int nesting = 0;
            while (j < s.length)
            {
                immutable c = s[j];
                if (c == '\\' && j + 1 < s.length && isAsciiPunct(s[j + 1]))
                    j += 2;
                else if (c == '(')
                {
                    ++nesting;
                    ++j;
                    if (nesting > 32)
                        return false;
                }
                else if (c == ')')
                {
                    if (nesting == 0)
                        break;
                    --nesting;
                    ++j;
                }
                else if (isAsciiWs(c))
                    break;
                else
                    ++j;
            }
            if (j >= s.length || nesting != 0)
                return false;
            destStart = i;
            destEnd = j;
            i = j;
        }
        int k = skipWs(i);
        hasTitle = false;
        if (k > i && k < s.length && (s[k] == '"' || s[k] == '\'' || s[k] == '('))
        {
            immutable te = scanTitle(k);
            if (te >= 0)
            {
                title = cleanString(s[k + 1 .. te]);
                hasTitle = true;
                k = skipWs(te + 1);
            }
        }
        if (k >= s.length || s[k] != ')')
            return false;
        url = cleanString(trimWs(s[destStart .. destEnd]));
        endPos = k + 1;
        return true;
    }

    private void handleCloseBracket()
    {
        if (bracketCount == 0)
        {
            addText("]");
            ++pos;
            return;
        }
        Bracket opener = bracketStack[bracketCount - 1];
        if (!opener.image && linkClosed)
        {
            --bracketCount;
            addText("]");
            ++pos;
            return;
        }
        string url, title;
        bool hasTitle;
        int endPos;
        if (!parseInlineLink(url, title, hasTitle, endPos))
        {
            --bracketCount;
            addText("]");
            ++pos;
            return;
        }
        auto node = new Node(opener.image ? NodeKind.image : NodeKind.link);
        node.url = url;
        node.title = title;
        node.hasTitle = hasTitle;
        for (Node tmp = opener.node.next; tmp !is null;)
        {
            Node nx = tmp.next;
            tmp.unlink();
            node.appendChild(tmp);
            tmp = nx;
        }
        block.appendChild(node);
        opener.node.unlink();
        processEmphasis(opener.position);
        --bracketCount;
        if (!opener.image)
            linkClosed = true;
        pos = endPos;
    }
}
