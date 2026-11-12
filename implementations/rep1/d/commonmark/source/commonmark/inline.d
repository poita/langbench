/**
 * Phase 2 of the conversion: parsing the raw content of paragraphs and headings
 * into inline nodes.
 *
 * The parser scans the content left to right keeping a delimiter stack (for
 * `*` and `_` runs) and a bracket stack (for `[` and `![`), and resolves
 * emphasis with the "process emphasis" algorithm of the CommonMark
 * specification, using `openers_bottom` bounds so that the work is linear in
 * the length of the content. Code spans use a memo of the last position seen
 * for each backtick run length. Nothing here is recursive, so inline nesting
 * thousands of levels deep is fine.
 *
 * Nodes live in a flat array (`InlineNode[]`) and refer to each other by
 * index; index 0 is always the root. Wrapping a range of siblings in an
 * emphasis or link node is O(1) apart from re-pointing each moved node's
 * parent.
 */
module commonmark.inline;

import commonmark.text;

/// Kinds of inline nodes.
enum InlineKind : ubyte
{
    /// The root; its children are the top-level inlines.
    root,
    /// Literal text (`InlineNode.text`).
    text,
    /// A soft line break.
    softBreak,
    /// A hard line break.
    lineBreak,
    /// A code span (`InlineNode.text` is the content).
    code,
    /// Emphasis.
    emph,
    /// Strong emphasis.
    strong,
    /// A link: `text` is the destination, `title` the optional title.
    link,
    /// An image: `text` is the destination, `title` the optional title.
    image,
}

/// Marks "no node" in `InlineNode` links.
enum int noNode = -1;

/// A node in the inline tree. Links refer to other nodes by index.
struct InlineNode
{
    /// Node kind.
    InlineKind kind;
    /// Index of the parent, previous and next sibling, first and last child.
    int parent = noNode, prev = noNode, next = noNode, firstChild = noNode, lastChild = noNode;
    /// Literal text, code content, or the (cleaned) link destination.
    string text;
    /// Link or image title (valid if `hasTitle`).
    string title;
    /// Whether a title is present (it may be empty).
    bool hasTitle;
}

/**
 * An inline parser. A parser object keeps its working buffers between calls so
 * that parsing many paragraphs does not reallocate.
 */
final class InlineParser
{
    private struct Delim
    {
        char ch;
        bool canOpen, canClose;
        int origLen;
        int node;
        int pos;
        int prev = noNode, next = noNode;
    }

    private struct Bracket
    {
        bool image;
        int node;
        int pos;
    }

    private InlineNode[] nodes;
    private Delim[] delims;
    private Bracket[] brackets;
    private int top = noNode; // top of the delimiter stack
    private bool linkClosed;
    private string s;

    // Backtick memo.
    private size_t[] lastTick;
    private bool ticksScanned;

    /**
     * Parses the content of one paragraph or heading.
     *
     * Returns: the node array; element 0 is the root. The array is only valid
     * until the next call to `parse`.
     */
    const(InlineNode)[] parse(string content)
    {
        s = trimRight(content);
        nodes.length = 1;
        nodes[0] = InlineNode(InlineKind.root);
        delims.length = 0;
        brackets.length = 0;
        top = noNode;
        linkClosed = true;
        ticksScanned = false;
        lastTick[] = 0;

        size_t pos = 0;
        immutable len = s.length;
        while (pos < len)
        {
            switch (s[pos])
            {
            case '\n':
                pos = parseNewline(pos);
                break;
            case '`':
                pos = parseBackticks(pos);
                break;
            case '\\':
                pos = parseBackslash(pos);
                break;
            case '&':
                pos = parseEntity(pos);
                break;
            case '<':
                pos = parseAutolink(pos);
                break;
            case '*':
            case '_':
                pos = parseDelimiterRun(pos);
                break;
            case '[':
                addText(s[pos .. pos + 1]);
                brackets ~= Bracket(false, cast(int) nodes.length - 1, cast(int) pos + 1);
                linkClosed = false;
                ++pos;
                break;
            case '!':
                if (pos + 1 < len && s[pos + 1] == '[')
                {
                    addText(s[pos .. pos + 2]);
                    brackets ~= Bracket(true, cast(int) nodes.length - 1, cast(int) pos + 2);
                    pos += 2;
                }
                else
                {
                    addText(s[pos .. pos + 1]);
                    ++pos;
                }
                break;
            case ']':
                pos = parseCloseBracket(pos);
                break;
            default:
                pos = parseText(pos);
                break;
            }
        }
        processEmphasis(0);
        return nodes;
    }

    // ---- node management -------------------------------------------------

    private int newNode(InlineKind kind, string text = null)
    {
        nodes ~= InlineNode(kind);
        nodes[$ - 1].text = text;
        return cast(int) nodes.length - 1;
    }

    private void appendChild(int parent, int n)
    {
        nodes[n].parent = parent;
        immutable last = nodes[parent].lastChild;
        nodes[n].prev = last;
        nodes[n].next = noNode;
        if (last != noNode)
            nodes[last].next = n;
        else
            nodes[parent].firstChild = n;
        nodes[parent].lastChild = n;
    }

    private int addText(string t)
    {
        immutable n = newNode(InlineKind.text, t);
        appendChild(0, n);
        return n;
    }

    private int addNode(InlineKind kind)
    {
        immutable n = newNode(kind);
        appendChild(0, n);
        return n;
    }

    private void unlink(int n)
    {
        immutable p = nodes[n].parent;
        immutable pr = nodes[n].prev;
        immutable nx = nodes[n].next;
        if (pr != noNode)
            nodes[pr].next = nx;
        else
            nodes[p].firstChild = nx;
        if (nx != noNode)
            nodes[nx].prev = pr;
        else
            nodes[p].lastChild = pr;
        nodes[n].parent = nodes[n].prev = nodes[n].next = noNode;
    }

    /// Creates a node of `kind` that takes over the sibling range
    /// `first .. last` (which follows `after`) and sits right after `after`.
    /// `first` may be `noNode` for an empty range.
    private int wrap(InlineKind kind, int after, int first, int last)
    {
        immutable w = newNode(kind);
        immutable parent = nodes[after].parent;
        immutable nx = first == noNode ? nodes[after].next : nodes[last].next;
        nodes[w].parent = parent;
        nodes[w].prev = after;
        nodes[w].next = nx;
        nodes[after].next = w;
        if (nx != noNode)
            nodes[nx].prev = w;
        else
            nodes[parent].lastChild = w;
        if (first != noNode)
        {
            nodes[first].prev = noNode;
            nodes[last].next = noNode;
            nodes[w].firstChild = first;
            nodes[w].lastChild = last;
            for (int i = first; i != noNode; i = nodes[i].next)
                nodes[i].parent = w;
        }
        return w;
    }

    // ---- simple constructs -----------------------------------------------

    private size_t parseText(size_t pos)
    {
        size_t end = pos + 1;
        immutable len = s.length;
        while (end < len)
        {
            switch (s[end])
            {
            case '\n': case '`': case '\\': case '&': case '<': case '*': case '_':
            case '[': case ']': case '!':
                goto done;
            default:
                ++end;
            }
        }
    done:
        size_t stop = end;
        if (end < len && s[end] == '\n')
            while (stop > pos && isSpace(s[stop - 1]))
                --stop;
        if (stop > pos)
            addText(s[pos .. stop]);
        return end;
    }

    private size_t parseNewline(size_t pos)
    {
        immutable hard = pos >= 2 && s[pos - 1] == ' ' && s[pos - 2] == ' ';
        addNode(hard ? InlineKind.lineBreak : InlineKind.softBreak);
        ++pos;
        while (pos < s.length && isSpaceOrTab(s[pos]))
            ++pos;
        return pos;
    }

    private size_t parseBackslash(size_t pos)
    {
        if (pos + 1 < s.length)
        {
            immutable c = s[pos + 1];
            if (isPunct(c))
            {
                addText(s[pos + 1 .. pos + 2]);
                return pos + 2;
            }
            if (c == '\n')
            {
                addNode(InlineKind.lineBreak);
                return pos + 2;
            }
        }
        addText(s[pos .. pos + 1]);
        return pos + 1;
    }

    private size_t parseEntity(size_t pos)
    {
        dchar cp;
        immutable m = matchEntity(s, pos, cp);
        if (m == 0)
        {
            addText(s[pos .. pos + 1]);
            return pos + 1;
        }
        addText(encodeChar(cp));
        return pos + m;
    }

    private static string encodeChar(dchar cp)
    {
        char[4] buf;
        immutable n = encodeUtf8(buf, cp);
        return buf[0 .. n].idup;
    }

    // ---- code spans ------------------------------------------------------

    /// Finds the start of a run of exactly `n` backticks at or after `from`,
    /// using the memo of last-seen run positions. Returns `size_t.max` if none.
    private size_t findBacktickRun(size_t n, size_t from)
    {
        if (ticksScanned && lastTick[n] <= from)
            return size_t.max;
        immutable len = s.length;
        size_t i = from;
        while (i < len)
        {
            if (s[i] != '`')
            {
                ++i;
                continue;
            }
            immutable st = i;
            while (i < len && s[i] == '`')
                ++i;
            immutable k = i - st;
            if (k >= lastTick.length)
                lastTick.length = k + 1;
            lastTick[k] = st;
            if (k == n)
                return st;
        }
        ticksScanned = true;
        return size_t.max;
    }

    private size_t parseBackticks(size_t pos)
    {
        size_t p = pos;
        while (p < s.length && s[p] == '`')
            ++p;
        immutable n = p - pos;
        if (n >= lastTick.length)
            lastTick.length = n + 1;
        immutable close = findBacktickRun(n, p);
        if (close == size_t.max)
        {
            addText(s[pos .. p]);
            return p;
        }
        string content = s[p .. close];
        bool hasNewline = false;
        foreach (c; content)
            if (c == '\n')
            {
                hasNewline = true;
                break;
            }
        if (hasNewline)
        {
            char[] t = content.dup;
            foreach (ref c; t)
                if (c == '\n')
                    c = ' ';
            content = (() @trusted => cast(string) t)();
        }
        if (content.length >= 2 && content[0] == ' ' && content[$ - 1] == ' ')
        {
            bool allSpaces = true;
            foreach (c; content)
                if (c != ' ')
                {
                    allSpaces = false;
                    break;
                }
            if (!allSpaces)
                content = content[1 .. $ - 1];
        }
        immutable node = addNode(InlineKind.code);
        nodes[node].text = content;
        return close + n;
    }

    // ---- autolinks -------------------------------------------------------

    private static bool isLocalPartChar(char c)
    {
        if (isAlnum(c))
            return true;
        switch (c)
        {
        case '.': case '!': case '#': case '$': case '%': case '&': case '\'': case '*':
        case '+': case '/': case '=': case '?': case '^': case '_': case '`': case '{':
        case '|': case '}': case '~': case '-':
            return true;
        default:
            return false;
        }
    }

    /// Returns the number of bytes of an autolink starting at `pos` (the `<`),
    /// or 0. Sets `email` for email autolinks.
    private size_t scanAutolink(size_t pos, out bool email)
    {
        immutable len = s.length;
        size_t i = pos + 1;
        // URI autolink: scheme of 2..32 characters, a colon, then no
        // whitespace, control, `<` or `>` up to the closing `>`.
        if (i < len && isAlpha(s[i]))
        {
            size_t j = i + 1;
            while (j < len && j - i < 32 && (isAlnum(s[j]) || s[j] == '.' || s[j] == '+' || s[j] == '-'))
                ++j;
            if (j - i >= 2 && j < len && s[j] == ':')
            {
                ++j;
                while (j < len && cast(ubyte) s[j] > 0x20 && s[j] != '<' && s[j] != '>')
                    ++j;
                if (j < len && s[j] == '>')
                    return j + 1 - pos;
            }
        }
        // Email autolink.
        size_t j = i;
        while (j < len && isLocalPartChar(s[j]))
            ++j;
        if (j == i || j >= len || s[j] != '@')
            return 0;
        ++j;
        immutable domainStart = j;
        while (j < len && (isAlnum(s[j]) || s[j] == '-' || s[j] == '.'))
            ++j;
        if (j >= len || s[j] != '>' || j == domainStart)
            return 0;
        size_t labelStart = domainStart;
        for (size_t k = domainStart; k <= j; ++k)
        {
            if (k == j || s[k] == '.')
            {
                immutable n = k - labelStart;
                if (n == 0 || n > 63 || s[labelStart] == '-' || s[k - 1] == '-')
                    return 0;
                labelStart = k + 1;
            }
        }
        email = true;
        return j + 1 - pos;
    }

    private size_t parseAutolink(size_t pos)
    {
        bool email;
        immutable m = scanAutolink(pos, email);
        if (m == 0)
        {
            addText(s[pos .. pos + 1]);
            return pos + 1;
        }
        immutable text = decodeEntities(s[pos + 1 .. pos + m - 1]);
        immutable link = addNode(InlineKind.link);
        nodes[link].text = email ? "mailto:" ~ text : text;
        immutable child = newNode(InlineKind.text, text);
        appendChild(link, child);
        return pos + m;
    }

    // ---- emphasis delimiters ---------------------------------------------

    private size_t parseDelimiterRun(size_t pos)
    {
        immutable ch = s[pos];
        size_t end = pos;
        while (end < s.length && s[end] == ch)
            ++end;
        immutable before = pos == 0 ? '\n' : s[pos - 1];
        immutable after = end >= s.length ? '\n' : s[end];
        immutable beforeSpace = isSpace(before), afterSpace = isSpace(after);
        immutable beforePunct = isPunct(before), afterPunct = isPunct(after);
        immutable leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct);
        immutable rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct);
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
        immutable node = addText(s[pos .. end]);
        if (canOpen || canClose)
        {
            Delim d;
            d.ch = ch;
            d.canOpen = canOpen;
            d.canClose = canClose;
            d.origLen = cast(int)(end - pos);
            d.node = node;
            d.pos = cast(int) end;
            d.prev = top;
            delims ~= d;
            immutable idx = cast(int) delims.length - 1;
            if (top != noNode)
                delims[top].next = idx;
            top = idx;
        }
        return end;
    }

    private void unlinkDelim(int i)
    {
        immutable p = delims[i].prev, n = delims[i].next;
        if (p != noNode)
            delims[p].next = n;
        if (n != noNode)
            delims[n].prev = p;
    }

    /// The "process emphasis" algorithm over delimiters at positions
    /// `>= bottomPos`; afterwards those delimiters are removed.
    private void processEmphasis(int bottomPos)
    {
        int below = top;
        int first = noNode;
        while (below != noNode && delims[below].pos >= bottomPos)
        {
            first = below;
            below = delims[below].prev;
        }
        if (first == noNode)
            return;

        int[12] openersBottom = bottomPos;
        int closer = first;
        while (closer != noNode)
        {
            immutable cd = delims[closer];
            if (!cd.canClose)
            {
                closer = cd.next;
                continue;
            }
            immutable kind = (cd.ch == '_' ? 6 : 0) + (cd.canOpen ? 3 : 0) + cd.origLen % 3;
            int opener = cd.prev;
            int found = noNode;
            while (opener != noNode && delims[opener].pos >= openersBottom[kind])
            {
                immutable od = delims[opener];
                if (od.canOpen && od.ch == cd.ch
                    && (!(cd.canOpen || od.canClose) || cd.origLen % 3 == 0
                        || (od.origLen + cd.origLen) % 3 != 0))
                {
                    found = opener;
                    break;
                }
                opener = od.prev;
            }
            if (found == noNode)
            {
                openersBottom[kind] = cd.pos;
                immutable nx = cd.next;
                if (!cd.canOpen)
                    unlinkDelim(closer);
                closer = nx;
                continue;
            }

            immutable openerNode = delims[found].node;
            immutable closerNode = cd.node;
            immutable use = (nodes[openerNode].text.length >= 2 && nodes[closerNode].text.length >= 2) ? 2 : 1;
            nodes[openerNode].text = nodes[openerNode].text[0 .. $ - use];
            nodes[closerNode].text = nodes[closerNode].text[use .. $];

            // Drop the delimiters between opener and closer.
            delims[found].next = closer;
            delims[closer].prev = found;

            int first2 = nodes[openerNode].next;
            int last2 = nodes[closerNode].prev;
            if (first2 == closerNode)
                first2 = last2 = noNode;
            wrap(use == 2 ? InlineKind.strong : InlineKind.emph, openerNode, first2, last2);

            if (nodes[openerNode].text.length == 0)
            {
                unlink(openerNode);
                unlinkDelim(found);
            }
            if (nodes[closerNode].text.length == 0)
            {
                unlink(closerNode);
                immutable nx = delims[closer].next;
                unlinkDelim(closer);
                closer = nx;
            }
        }
        top = below;
        if (below != noNode)
            delims[below].next = noNode;
    }

    // ---- links and images ------------------------------------------------

    private size_t skipSpace(size_t i) const
    {
        while (i < s.length && isSpace(s[i]))
            ++i;
        return i;
    }

    /// Scans a link destination at `i`; returns the end (exclusive) or
    /// `size_t.max`, and the raw destination in `dest`.
    private size_t scanDestination(size_t i, out string dest) const
    {
        immutable len = s.length;
        if (i < len && s[i] == '<')
        {
            size_t j = i + 1;
            while (j < len)
            {
                immutable c = s[j];
                if (c == '>')
                {
                    ++j;
                    break;
                }
                else if (c == '\\')
                    j += 2;
                else if (c == '\n' || c == '<')
                    return size_t.max;
                else
                    ++j;
            }
            if (j >= len)
                return size_t.max;
            dest = s[i + 1 .. j - 1];
            return j;
        }
        size_t j = i;
        int nesting = 0;
        while (j < len)
        {
            immutable c = s[j];
            if (c == '\\' && j + 1 < len && isPunct(s[j + 1]))
                j += 2;
            else if (c == '(')
            {
                ++nesting;
                ++j;
                if (nesting > 32)
                    return size_t.max;
            }
            else if (c == ')')
            {
                if (nesting == 0)
                    break;
                --nesting;
                ++j;
            }
            else if (isSpace(c))
                break;
            else
                ++j;
        }
        if (j >= len || nesting != 0)
            return size_t.max;
        dest = s[i .. j];
        return j;
    }

    /// Scans a link title at `i` (which holds `"`, `'` or `(`): the longest
    /// match in which the closing delimiter (and `(`, for parenthesised
    /// titles) occurs only after a backslash. Returns the end (exclusive) or
    /// `size_t.max`.
    private size_t scanTitle(size_t i) const
    {
        immutable open = s[i];
        immutable close = open == '(' ? ')' : open;
        size_t best = size_t.max;
        for (size_t j = i + 1; j < s.length; ++j)
        {
            immutable c = s[j];
            immutable escaped = s[j - 1] == '\\';
            if (c == close)
            {
                best = j + 1;
                if (!escaped)
                    break;
            }
            else if (open == '(' && c == '(' && !escaped)
                break;
        }
        return best;
    }

    /// Tries to parse `(destination "title")` at `p`. Returns the position
    /// after the `)` or 0.
    private size_t scanInlineLink(size_t p, out string dest, out string title, out bool hasTitle) const
    {
        immutable len = s.length;
        if (p >= len || s[p] != '(')
            return 0;
        size_t i = skipSpace(p + 1);
        immutable end = scanDestination(i, dest);
        if (end == size_t.max)
            return 0;
        i = skipSpace(end);
        if (i > end && i < len && (s[i] == '"' || s[i] == '\'' || s[i] == '('))
        {
            immutable te = scanTitle(i);
            if (te != size_t.max)
            {
                title = s[i + 1 .. te - 1];
                hasTitle = true;
                i = te;
            }
        }
        i = skipSpace(i);
        if (i < len && s[i] == ')')
            return i + 1;
        return 0;
    }

    private size_t parseCloseBracket(size_t pos)
    {
        immutable after = pos + 1;
        if (brackets.length == 0)
        {
            addText(s[pos .. after]);
            return after;
        }
        immutable opener = brackets[$ - 1];
        if (!opener.image && linkClosed)
        {
            brackets.length = brackets.length - 1;
            addText(s[pos .. after]);
            return after;
        }
        string dest, title;
        bool hasTitle;
        immutable end = scanInlineLink(after, dest, title, hasTitle);
        if (end == 0)
        {
            brackets.length = brackets.length - 1;
            addText(s[pos .. after]);
            return after;
        }

        immutable openerNode = opener.node;
        immutable parent = nodes[openerNode].parent;
        immutable first = nodes[openerNode].next;
        immutable last = first == noNode ? noNode : nodes[parent].lastChild;
        immutable node = wrap(opener.image ? InlineKind.image : InlineKind.link, openerNode, first, last);
        nodes[node].text = cleanString(trim(dest));
        if (hasTitle)
        {
            nodes[node].title = cleanString(title);
            nodes[node].hasTitle = true;
        }
        unlink(openerNode);
        processEmphasis(opener.pos);
        brackets.length = brackets.length - 1;
        if (!opener.image)
            linkClosed = true;
        return end;
    }
}

version (unittest)
{
    private string dump(const(InlineNode)[] nodes, int n = 0)
    {
        import std.format : format;

        string s;
        final switch (nodes[n].kind)
        {
        case InlineKind.root: s = ""; break;
        case InlineKind.text: s = nodes[n].text; break;
        case InlineKind.softBreak: s = "~"; break;
        case InlineKind.lineBreak: s = "^"; break;
        case InlineKind.code: s = "`" ~ nodes[n].text ~ "`"; break;
        case InlineKind.emph: s = "em"; break;
        case InlineKind.strong: s = "st"; break;
        case InlineKind.link: s = "a<" ~ nodes[n].text ~ ">"; break;
        case InlineKind.image: s = "img<" ~ nodes[n].text ~ ">"; break;
        }
        if (nodes[n].kind != InlineKind.text && nodes[n].kind != InlineKind.code
            && nodes[n].kind != InlineKind.softBreak && nodes[n].kind != InlineKind.lineBreak)
        {
            if (nodes[n].kind != InlineKind.root)
                s ~= "(";
            for (int c = nodes[n].firstChild; c != noNode; c = nodes[c].next)
                s ~= dump(nodes, c);
            if (nodes[n].kind != InlineKind.root)
                s ~= ")";
        }
        return s;
    }

    private string parseDump(string md)
    {
        auto p = new InlineParser;
        return dump(p.parse(md));
    }
}

unittest
{
    assert(parseDump("a *b* **c**") == "a em(b) st(c)");
    assert(parseDump("*foo**bar**baz*") == "em(foo" ~ "st(bar)" ~ "baz)");
    assert(parseDump("_a_b_") == "em(a_b)");
    assert(parseDump("***a***") == "em(st(a))");
}

unittest
{
    assert(parseDump("`a` ``b ` c``") == "`a` `b ` c`");
    assert(parseDump("`` ` ``") == "```");
    assert(parseDump("`unclosed") == "`unclosed");
    assert(parseDump("a  \nb\nc\\\nd") == "a^b~c^d");
}

unittest
{
    assert(parseDump("[a](/u)") == "a</u>(a)");
    assert(parseDump("![a *b*](/u \"t\")") == "img</u>(a em(b))");
    assert(parseDump("[a] (b)") == "[a] (b)");
    assert(parseDump("[a [b](/c) d](/e)") == "[a a</c>(b) d](/e)");
    assert(parseDump("[a](<b c>)") == "a<b c>(a)");
    assert(parseDump("[a](b c)") == "[a](b c)");
    assert(parseDump("<http://a.b/c> <me@x.org> <a b>") == "a<http://a.b/c>(http://a.b/c) a<mailto:me@x.org>(me@x.org) <a b>");
}

unittest
{
    assert(parseDump("&amp; &#65; &foo; \\* \\a") == "& A &foo; * \\a");
    // Deep emphasis nesting must not overflow the stack.
    string deep;
    foreach (_; 0 .. 5000)
        deep ~= "*a ";
    foreach (_; 0 .. 5000)
        deep ~= "a* ";
    auto p = new InlineParser;
    assert(p.parse(deep).length > 5000);
}
