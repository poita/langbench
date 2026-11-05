/// Phase 2: parsing the content of a paragraph or heading into inline nodes.
module commonmark.inlines;

import commonmark.buffer;
import commonmark.chars;
import commonmark.entities;
import commonmark.scanners;

/// The kinds of inline nodes.
enum InlineKind : ubyte
{
    root,
    text,
    softBreak,
    hardBreak,
    code,
    emph,
    strong,
    link,
    image,
}

/// One inline node. Nodes are stored in an arena and linked by index
/// (0 = none). Text and code nodes carry a span (`start`, `length`) into
/// either the parsed content or the side buffer (`inSide`). Links and images
/// carry their destination as a span of the side buffer, plus an optional
/// title span (`start2`, `length2`).
struct Inline
{
    InlineKind kind;
    bool inSide;
    bool hasTitle;
    int parent, firstChild, lastChild, next, prev;
    int start, length;
    int start2, length2;
}

private struct Delim
{
    int prev, next;
    int node;
    int position;
    int origLength;
    char ch;
    bool canOpen, canClose;
}

private struct Bracket
{
    int node;
    int position;
    int delimTail;
    bool image;
}

private immutable bool[256] special = () {
    bool[256] t;
    foreach (c; "\n`\\&<*_[]!")
        t[c] = true;
    return t;
}();

/// Reusable inline parser. Call `parse` for each block's content; the
/// resulting tree is valid until the next call.
struct InlineParser
{
    private const(char)[] s;
    private Inline[] nodes;
    private int nodeCount;
    private Delim[] delims;
    private int delimCount;
    private int dTail;
    private Bracket[] brackets;
    private size_t bracketCount;
    private bool linkClosed;
    private size_t[102] btLast;
    private bool btScanned;
    private Buffer side;
    private Buffer scratch;

    /// Index of the root node of the tree built by `parse`.
    enum root = 1;

    /// Parse `content` (trailing whitespace is ignored).
    void parse(const(char)[] content)
    {
        size_t n = content.length;
        while (n > 0 && isWhitespace(content[n - 1]))
            --n;
        s = content[0 .. n];
        if (nodes.length == 0)
            nodes.length = 64;
        nodeCount = 2;
        nodes[0] = Inline.init;
        nodes[1] = Inline.init;
        nodes[1].kind = InlineKind.root;
        if (delims.length == 0)
            delims.length = 32;
        delimCount = 1;
        delims[0] = Delim.init;
        dTail = 0;
        bracketCount = 0;
        linkClosed = true;
        btLast[] = 0;
        btScanned = false;
        side.clear();
        scan();
        processEmphasis(0, 0);
    }

    /// Node access.
    ref const(Inline) node(int i) const
    {
        return nodes[i];
    }

    /// The text of a text or code node.
    const(char)[] textOf(int i) const
    {
        const nd = &nodes[i];
        return nd.inSide ? side.data[nd.start .. nd.start + nd.length]
            : s[nd.start .. nd.start + nd.length];
    }

    /// The destination of a link or image.
    const(char)[] destOf(int i) const
    {
        return side.data[nodes[i].start .. nodes[i].start + nodes[i].length];
    }

    /// The title of a link or image (only meaningful if `hasTitle`).
    const(char)[] titleOf(int i) const
    {
        return side.data[nodes[i].start2 .. nodes[i].start2 + nodes[i].length2];
    }

    // ---- node arena ---------------------------------------------------------

    private int newNode(InlineKind kind)
    {
        if (nodeCount == nodes.length)
            nodes.length = nodes.length * 2;
        immutable i = nodeCount++;
        nodes[i] = Inline.init;
        nodes[i].kind = kind;
        return i;
    }

    private void appendChild(int parent, int child)
    {
        nodes[child].parent = parent;
        immutable last = nodes[parent].lastChild;
        nodes[child].prev = last;
        if (last)
            nodes[last].next = child;
        else
            nodes[parent].firstChild = child;
        nodes[parent].lastChild = child;
    }

    private int addNode(InlineKind kind)
    {
        immutable i = newNode(kind);
        appendChild(root, i);
        return i;
    }

    private int addText(size_t start, size_t len, bool inSide = false)
    {
        immutable i = addNode(InlineKind.text);
        nodes[i].start = cast(int) start;
        nodes[i].length = cast(int) len;
        nodes[i].inSide = inSide;
        return i;
    }

    private void unlink(int i)
    {
        immutable p = nodes[i].parent;
        immutable pv = nodes[i].prev;
        immutable nx = nodes[i].next;
        if (pv)
            nodes[pv].next = nx;
        else
            nodes[p].firstChild = nx;
        if (nx)
            nodes[nx].prev = pv;
        else
            nodes[p].lastChild = pv;
        nodes[i].parent = nodes[i].prev = nodes[i].next = 0;
    }

    private int newDelim()
    {
        if (delimCount == delims.length)
            delims.length = delims.length * 2;
        delims[delimCount] = Delim.init;
        return delimCount++;
    }

    private void removeDelim(int d)
    {
        immutable pv = delims[d].prev;
        immutable nx = delims[d].next;
        delims[pv].next = nx;
        if (nx)
            delims[nx].prev = pv;
        else
            dTail = pv;
    }

    // ---- scanning -------------------------------------------------------------

    private void scan()
    {
        immutable n = s.length;
        size_t pos = 0;
        while (pos < n)
        {
            immutable c = s[pos];
            switch (c)
            {
            case '\n':
            {
                immutable hard = pos >= 2 && s[pos - 1] == ' ' && s[pos - 2] == ' ';
                addNode(hard ? InlineKind.hardBreak : InlineKind.softBreak);
                ++pos;
                while (pos < n && isSpaceOrTab(s[pos]))
                    ++pos;
                break;
            }
            case '`':
                pos = scanCodeSpan(pos);
                break;
            case '\\':
                if (pos + 1 < n && isAsciiPunct(s[pos + 1]))
                {
                    addText(pos + 1, 1);
                    pos += 2;
                }
                else if (pos + 1 < n && s[pos + 1] == '\n')
                {
                    addNode(InlineKind.hardBreak);
                    pos += 2;
                }
                else
                {
                    addText(pos, 1);
                    ++pos;
                }
                break;
            case '&':
            {
                dchar cp;
                immutable m = matchEntity(s, pos, cp);
                if (m)
                {
                    immutable st = side.length;
                    putUtf8(side, cp);
                    addText(st, side.length - st, true);
                    pos += m;
                }
                else
                {
                    addText(pos, 1);
                    ++pos;
                }
                break;
            }
            case '<':
            {
                bool isEmail;
                immutable e = scanAutolink(s, pos + 1, isEmail);
                if (e >= 0)
                {
                    makeAutolink(pos + 1, e, isEmail);
                    pos = e + 1;
                }
                else
                {
                    addText(pos, 1);
                    ++pos;
                }
                break;
            }
            case '*':
            case '_':
                pos = scanDelimRun(pos);
                break;
            case '[':
            {
                immutable nd = addText(pos, 1);
                pushBracket(nd, false, pos + 1);
                linkClosed = false;
                ++pos;
                break;
            }
            case '!':
                if (pos + 1 < n && s[pos + 1] == '[')
                {
                    immutable nd = addText(pos, 2);
                    pushBracket(nd, true, pos + 2);
                    pos += 2;
                }
                else
                {
                    addText(pos, 1);
                    ++pos;
                }
                break;
            case ']':
                pos = closeBracket(pos);
                break;
            default:
            {
                immutable st = pos;
                while (pos < n && !special[s[pos]])
                    ++pos;
                size_t end = pos;
                if (pos < n && s[pos] == '\n')
                    while (end > st && isSpaceOrTab(s[end - 1]))
                        --end;
                if (end > st)
                    addText(st, end - st);
                break;
            }
            }
        }
    }

    private void pushBracket(int node, bool image, size_t position)
    {
        if (bracketCount == brackets.length)
            brackets.length = brackets.length ? brackets.length * 2 : 16;
        brackets[bracketCount++] = Bracket(node, cast(int) position, dTail, image);
    }

    private size_t scanCodeSpan(size_t pos)
    {
        immutable n = s.length;
        immutable start = pos;
        while (pos < n && s[pos] == '`')
            ++pos;
        immutable len = pos - start;
        immutable close = findBacktickRun(len, pos);
        if (close < 0)
        {
            addText(start, len);
            return pos;
        }
        immutable sideStart = side.length;
        foreach (c; s[pos .. close])
            side.put(c == '\n' ? ' ' : c);
        size_t cs = sideStart;
        size_t cl = side.length - sideStart;
        auto d = side.data;
        if (cl >= 2 && d[cs] == ' ' && d[cs + cl - 1] == ' ')
        {
            bool allSpaces = true;
            foreach (c; d[cs .. cs + cl])
                if (c != ' ')
                {
                    allSpaces = false;
                    break;
                }
            if (!allSpaces)
            {
                ++cs;
                cl -= 2;
            }
        }
        immutable nd = addNode(InlineKind.code);
        nodes[nd].start = cast(int) cs;
        nodes[nd].length = cast(int) cl;
        nodes[nd].inSide = true;
        return close + len;
    }

    /// Search for a backtick run of exactly `n` characters at or after `p`,
    /// using the per-length memo. Returns its start, or -1.
    private ptrdiff_t findBacktickRun(size_t n, size_t p)
    {
        immutable slot = n > 101 ? 101 : n;
        if (btScanned && btLast[slot] <= p)
            return -1;
        immutable end = s.length;
        size_t i = p;
        while (i < end)
        {
            if (s[i] != '`')
            {
                ++i;
                continue;
            }
            immutable st = i;
            while (i < end && s[i] == '`')
                ++i;
            immutable k = i - st;
            btLast[k > 101 ? 101 : k] = st;
            if (k == n)
                return st;
        }
        btScanned = true;
        return -1;
    }

    private void makeAutolink(size_t from, size_t to, bool isEmail)
    {
        immutable textStart = side.length;
        decodeEntities(s[from .. to], side);
        immutable textLen = side.length - textStart;
        size_t destStart = textStart;
        size_t destLen = textLen;
        if (isEmail)
        {
            destStart = side.length;
            side.put("mailto:");
            side.put(side.data[textStart .. textStart + textLen]);
            destLen = side.length - destStart;
        }
        immutable ln = addNode(InlineKind.link);
        nodes[ln].start = cast(int) destStart;
        nodes[ln].length = cast(int) destLen;
        immutable t = newNode(InlineKind.text);
        nodes[t].start = cast(int) textStart;
        nodes[t].length = cast(int) textLen;
        nodes[t].inSide = true;
        appendChild(ln, t);
    }

    private size_t scanDelimRun(size_t pos)
    {
        immutable n = s.length;
        immutable c = s[pos];
        immutable start = pos;
        while (pos < n && s[pos] == c)
            ++pos;
        immutable before = start > 0 ? s[start - 1] : '\n';
        immutable after = pos < n ? s[pos] : '\n';
        immutable afterWs = isWhitespace(after);
        immutable beforeWs = isWhitespace(before);
        immutable afterP = isAsciiPunct(after);
        immutable beforeP = isAsciiPunct(before);
        immutable leftFlanking = !afterWs && (!afterP || beforeWs || beforeP);
        immutable rightFlanking = !beforeWs && (!beforeP || afterWs || afterP);
        bool canOpen, canClose;
        if (c == '*')
        {
            canOpen = leftFlanking;
            canClose = rightFlanking;
        }
        else
        {
            canOpen = leftFlanking && (!rightFlanking || beforeP);
            canClose = rightFlanking && (!leftFlanking || afterP);
        }
        immutable nd = addText(start, pos - start);
        if (canOpen || canClose)
        {
            immutable d = newDelim();
            delims[d].prev = dTail;
            delims[dTail].next = d;
            dTail = d;
            delims[d].node = nd;
            delims[d].position = cast(int) pos;
            delims[d].origLength = cast(int)(pos - start);
            delims[d].ch = c;
            delims[d].canOpen = canOpen;
            delims[d].canClose = canClose;
        }
        return pos;
    }

    private size_t closeBracket(size_t pos)
    {
        if (bracketCount == 0)
        {
            addText(pos, 1);
            return pos + 1;
        }
        immutable op = brackets[bracketCount - 1];
        if (!op.image && linkClosed)
        {
            --bracketCount;
            addText(pos, 1);
            return pos + 1;
        }
        LinkTail tail;
        if (pos + 1 < s.length && s[pos + 1] == '(' && scanLinkTail(s, pos + 2, tail))
        {
            // Decode destination and title into the side buffer.
            auto dest = s[tail.destStart .. tail.destEnd];
            while (dest.length && isWhitespace(dest[0]))
                dest = dest[1 .. $];
            while (dest.length && isWhitespace(dest[$ - 1]))
                dest = dest[0 .. $ - 1];
            immutable dStart = side.length;
            cleanText(dest, side, scratch);
            immutable dLen = side.length - dStart;
            immutable tStart = side.length;
            if (tail.hasTitle)
                cleanText(s[tail.titleStart .. tail.titleEnd], side, scratch);
            immutable tLen = side.length - tStart;

            immutable ln = newNode(op.image ? InlineKind.image : InlineKind.link);
            nodes[ln].start = cast(int) dStart;
            nodes[ln].length = cast(int) dLen;
            nodes[ln].hasTitle = tail.hasTitle;
            nodes[ln].start2 = cast(int) tStart;
            nodes[ln].length2 = cast(int) tLen;

            // Move everything after the opener's text node into the new node.
            immutable par = nodes[op.node].parent;
            immutable first = nodes[op.node].next;
            immutable last = nodes[par].lastChild;
            if (first)
            {
                nodes[first].prev = 0;
                nodes[ln].firstChild = first;
                nodes[ln].lastChild = last;
                for (int c = first; c; c = nodes[c].next)
                    nodes[c].parent = ln;
                nodes[op.node].next = 0;
                nodes[par].lastChild = op.node;
            }
            appendChild(par, ln);
            unlink(op.node);

            processEmphasis(op.delimTail, op.position);
            dTail = op.delimTail;
            delims[dTail].next = 0;
            --bracketCount;
            if (!op.image)
                linkClosed = true;
            return tail.end;
        }
        --bracketCount;
        addText(pos, 1);
        return pos + 1;
    }

    // ---- emphasis -------------------------------------------------------------

    private void processEmphasis(int prevOfFirst, int bottom)
    {
        int[12] openersBottom = bottom;
        int closer = delims[prevOfFirst].next;
        while (closer)
        {
            immutable cl = delims[closer];
            if (!cl.canClose)
            {
                closer = cl.next;
                continue;
            }
            immutable kind = (cl.ch == '_' ? 6 : 0) + (cl.canOpen ? 3 : 0) + cl.origLength % 3;
            int opener = cl.prev;
            bool found = false;
            while (opener != 0 && delims[opener].position >= openersBottom[kind])
            {
                const op = &delims[opener];
                if (op.canOpen && op.ch == cl.ch)
                {
                    immutable bothEnds = cl.canOpen || op.canClose;
                    if (!bothEnds || cl.origLength % 3 == 0 || (op.origLength + cl.origLength) % 3 != 0)
                    {
                        found = true;
                        break;
                    }
                }
                opener = op.prev;
            }
            if (!found)
            {
                openersBottom[kind] = cl.position;
                immutable next = cl.next;
                if (!cl.canOpen)
                    removeDelim(closer);
                closer = next;
                continue;
            }

            immutable opNode = delims[opener].node;
            immutable clNode = cl.node;
            immutable use = (nodes[opNode].length >= 2 && nodes[clNode].length >= 2) ? 2 : 1;
            nodes[opNode].length -= use;
            nodes[clNode].start += use;
            nodes[clNode].length -= use;

            // Drop delimiters strictly between opener and closer.
            delims[opener].next = closer;
            delims[closer].prev = opener;

            // Wrap the nodes strictly between the two text nodes.
            immutable w = newNode(use == 2 ? InlineKind.strong : InlineKind.emph);
            immutable par = nodes[opNode].parent;
            immutable first = nodes[opNode].next;
            if (first != clNode)
            {
                immutable last = nodes[clNode].prev;
                nodes[first].prev = 0;
                nodes[last].next = 0;
                nodes[w].firstChild = first;
                nodes[w].lastChild = last;
                for (int c = first; c; c = nodes[c].next)
                    nodes[c].parent = w;
            }
            nodes[w].parent = par;
            nodes[w].prev = opNode;
            nodes[w].next = clNode;
            nodes[opNode].next = w;
            nodes[clNode].prev = w;

            if (nodes[opNode].length == 0)
            {
                unlink(opNode);
                removeDelim(opener);
            }
            if (nodes[clNode].length == 0)
            {
                unlink(clNode);
                immutable nx = delims[closer].next;
                removeDelim(closer);
                closer = nx;
            }
        }
    }
}
