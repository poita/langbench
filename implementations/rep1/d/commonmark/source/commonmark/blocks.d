/// Phase 1: line-by-line construction of the block structure.
module commonmark.blocks;

import commonmark.ast;
import commonmark.buffer;
import commonmark.chars;
import commonmark.entities;

/// Parse the block structure of `input` (UTF-8 text, LF line endings).
Document parseBlocks(const(char)[] input)
{
    auto p = BlockParser(input);
    p.run();
    return Document(p.blocks);
}

private bool canContain(BlockKind parent, BlockKind child) pure nothrow @nogc @safe
{
    switch (parent)
    {
    case BlockKind.document:
    case BlockKind.blockQuote:
    case BlockKind.item:
        return child != BlockKind.item;
    case BlockKind.list:
        return child == BlockKind.item;
    default:
        return false;
    }
}

private struct BlockParser
{
    const(char)[] data;
    Block[] blocks;
    int tip; // innermost open block

    // Per-line state.
    size_t ls; // start of the current line
    size_t le; // end of the current line (exclusive)
    size_t offset;
    int column;
    bool partialTab;
    size_t firstNonspace;
    int indent;
    bool blank;
    int lineNo;

    this(const(char)[] d)
    {
        data = d;
        blocks.reserve(64);
        Block doc;
        doc.kind = BlockKind.document;
        blocks ~= doc;
    }

    void run()
    {
        immutable n = data.length;
        size_t pos = 0;
        while (pos < n)
        {
            size_t e = pos;
            while (e < n && data[e] != '\n')
                ++e;
            processLine(pos, e);
            pos = e + 1;
        }
        while (tip != 0)
        {
            finalize(tip);
            tip = blocks[tip].parent;
        }
        blocks[0].open = false;
    }

    // ---- line scanning helpers -------------------------------------------

    char at(size_t p) const
    {
        return p < le ? data[p] : '\n';
    }

    void findFirstNonspace()
    {
        size_t p = offset;
        int col = column;
        for (;;)
        {
            immutable c = at(p);
            if (c == ' ')
            {
                ++p;
                ++col;
            }
            else if (c == '\t')
            {
                ++p;
                col += 4 - (col & 3);
            }
            else
                break;
        }
        firstNonspace = p;
        indent = col - column;
        blank = p >= le;
    }

    void advance(int count, bool columns)
    {
        while (count > 0 && offset < le)
        {
            if (data[offset] == '\t')
            {
                immutable toTab = 4 - (column & 3);
                if (columns)
                {
                    partialTab = toTab > count;
                    immutable adv = partialTab ? count : toTab;
                    column += adv;
                    if (!partialTab)
                        ++offset;
                    count -= adv;
                }
                else
                {
                    partialTab = false;
                    column += toTab;
                    ++offset;
                    --count;
                }
            }
            else
            {
                partialTab = false;
                ++column;
                ++offset;
                --count;
            }
        }
    }

    // ---- tree helpers -----------------------------------------------------

    int newBlock(int parent, BlockKind kind)
    {
        Block b;
        b.kind = kind;
        b.parent = parent;
        b.line = lineNo;
        immutable idx = cast(int) blocks.length;
        b.prev = blocks[parent].lastChild;
        blocks ~= b;
        if (blocks[parent].lastChild)
            blocks[blocks[parent].lastChild].next = idx;
        else
            blocks[parent].firstChild = idx;
        blocks[parent].lastChild = idx;
        return idx;
    }

    /// Close open blocks from the tip up to and including `b`.
    void closeThrough(int b)
    {
        immutable stop = blocks[b].parent;
        while (tip != stop)
        {
            finalize(tip);
            tip = blocks[tip].parent;
        }
    }

    /// Add a child of `kind` to `parent` (or the nearest ancestor that can
    /// hold it), closing blocks as needed. The new block becomes the tip.
    int addChild(int parent, BlockKind kind)
    {
        while (!canContain(blocks[parent].kind, kind))
        {
            closeThrough(parent);
            parent = blocks[parent].parent;
        }
        while (tip != parent)
        {
            finalize(tip);
            tip = blocks[tip].parent;
        }
        immutable idx = newBlock(parent, kind);
        tip = idx;
        return idx;
    }

    void addLine(int b, size_t end)
    {
        if (partialTab)
        {
            ++offset;
            foreach (_; 0 .. 4 - (column & 3))
                blocks[b].content ~= ' ';
        }
        if (end > offset)
            blocks[b].content ~= data[offset .. end];
        blocks[b].content ~= '\n';
    }

    // ---- finalization -----------------------------------------------------

    void finalize(int b)
    {
        blocks[b].open = false;
        final switch (blocks[b].kind)
        {
        case BlockKind.indentedCode:
            trimTrailingBlankLines(b);
            break;
        case BlockKind.fencedCode:
            extractInfo(b);
            break;
        case BlockKind.list:
            blocks[b].tight = computeTight(b);
            break;
        case BlockKind.document:
        case BlockKind.blockQuote:
        case BlockKind.item:
        case BlockKind.paragraph:
        case BlockKind.heading:
        case BlockKind.thematicBreak:
            break;
        }
    }

    void trimTrailingBlankLines(int b)
    {
        auto c = blocks[b].content;
        ptrdiff_t i = cast(ptrdiff_t) c.length - 1;
        while (i >= 0 && (c[i] == ' ' || c[i] == '\t' || c[i] == '\n'))
            --i;
        if (i < 0)
        {
            c = c[0 .. 0];
        }
        else
        {
            while (i < cast(ptrdiff_t) c.length && c[i] != '\n')
                ++i;
            c = c[0 .. i];
        }
        c ~= '\n';
        blocks[b].content = c;
    }

    void extractInfo(int b)
    {
        auto c = blocks[b].content;
        size_t nl = 0;
        while (nl < c.length && c[nl] != '\n')
            ++nl;
        Buffer decoded, info;
        decodeEntities(c[0 .. nl], decoded);
        auto d = decoded.data;
        while (d.length && isWhitespace(d[0]))
            d = d[1 .. $];
        while (d.length && isWhitespace(d[$ - 1]))
            d = d[0 .. $ - 1];
        unescapeBackslashes(d, info);
        blocks[b].info = info.idup;
        blocks[b].content = nl < c.length ? c[nl + 1 .. $] : c[0 .. 0];
    }

    bool endsWithBlankLine(int node)
    {
        int cur = node;
        while (cur != 0)
        {
            if (blocks[cur].lastLineChecked)
                return blocks[cur].lastLineBlank;
            blocks[cur].lastLineChecked = true;
            immutable k = blocks[cur].kind;
            if ((k == BlockKind.list || k == BlockKind.item) && blocks[cur].lastChild)
                cur = blocks[cur].lastChild;
            else
                return blocks[cur].lastLineBlank;
        }
        return false;
    }

    bool computeTight(int list)
    {
        for (int item = blocks[list].firstChild; item; item = blocks[item].next)
        {
            if (blocks[item].lastLineBlank && blocks[item].next)
                return false;
            for (int sub = blocks[item].firstChild; sub; sub = blocks[sub].next)
            {
                if ((blocks[item].next || blocks[sub].next) && endsWithBlankLine(sub))
                    return false;
            }
        }
        return true;
    }

    // ---- block start scanners ---------------------------------------------

    bool scanAtx(out int level, out size_t after)
    {
        size_t p = firstNonspace;
        int n = 0;
        while (at(p) == '#')
        {
            ++p;
            ++n;
        }
        if (n < 1 || n > 6)
            return false;
        if (p < le && !isSpaceOrTab(data[p]))
            return false;
        while (p < le && isSpaceOrTab(data[p]))
            ++p;
        level = n;
        after = p;
        return true;
    }

    bool scanFence(char fc, out int length)
    {
        size_t p = firstNonspace;
        while (p < le && data[p] == fc)
            ++p;
        immutable len = p - firstNonspace;
        if (len < 3)
            return false;
        if (fc == '`')
        {
            foreach (q; p .. le)
                if (data[q] == '`')
                    return false;
        }
        length = cast(int) len;
        return true;
    }

    bool scanSetext(char c)
    {
        size_t p = firstNonspace;
        while (at(p) == c)
            ++p;
        while (p < le && isSpaceOrTab(data[p]))
            ++p;
        return p >= le;
    }

    bool scanThematic(char c)
    {
        int count = 0;
        foreach (p; firstNonspace .. le)
        {
            immutable ch = data[p];
            if (ch == c)
                ++count;
            else if (!isSpaceOrTab(ch))
                return false;
        }
        return count >= 3;
    }

    bool parseListMarker(bool interrupts, out bool ordered, out char delim, out int start, out int width)
    {
        size_t pos = firstNonspace;
        immutable c = at(pos);
        size_t p;
        if (c == '*' || c == '-' || c == '+')
        {
            p = pos + 1;
            ordered = false;
            delim = c;
            start = 0;
        }
        else if (isDigit(c))
        {
            long v = 0;
            int digits = 0;
            p = pos;
            while (digits < 9 && isDigit(at(p)))
            {
                v = v * 10 + (at(p) - '0');
                ++p;
                ++digits;
            }
            immutable d = at(p);
            if (d != '.' && d != ')')
                return false;
            ++p;
            ordered = true;
            delim = d;
            start = cast(int) v;
        }
        else
            return false;
        if (!isWhitespace(at(p)))
            return false;
        if (interrupts)
        {
            if (ordered && start != 1)
                return false;
            size_t i = p;
            while (i < le && isSpaceOrTab(data[i]))
                ++i;
            if (i >= le)
                return false;
        }
        width = cast(int)(p - pos);
        return true;
    }

    // ---- the per-line algorithm -------------------------------------------

    void processLine(size_t lineStart, size_t e)
    {
        ls = lineStart;
        le = e;
        offset = lineStart;
        column = 0;
        partialTab = false;
        ++lineNo;
        immutable oldTip = tip;

        // Step 1: continue open blocks.
        int container = 0;
        bool allMatched = true;
        for (;;)
        {
            immutable child = blocks[container].lastChild;
            if (child == 0 || !blocks[child].open)
                break;
            findFirstNonspace();
            bool ok = false;
            final switch (blocks[child].kind)
            {
            case BlockKind.blockQuote:
                if (indent <= 3 && at(firstNonspace) == '>')
                {
                    advance(indent + 1, true);
                    if (isSpaceOrTab(at(offset)))
                        advance(1, true);
                    ok = true;
                }
                break;
            case BlockKind.item:
                if (indent >= blocks[child].markerOffset + blocks[child].padding)
                {
                    advance(blocks[child].markerOffset + blocks[child].padding, true);
                    ok = true;
                }
                else if (blank && blocks[child].firstChild != 0)
                {
                    advance(cast(int)(firstNonspace - offset), false);
                    ok = true;
                }
                break;
            case BlockKind.list:
                ok = true;
                break;
            case BlockKind.indentedCode:
                if (indent >= 4)
                {
                    advance(4, true);
                    ok = true;
                }
                else if (blank)
                {
                    advance(cast(int)(firstNonspace - offset), false);
                    ok = true;
                }
                break;
            case BlockKind.fencedCode:
                if (indent <= 3 && at(firstNonspace) == blocks[child].fenceChar)
                {
                    size_t p = firstNonspace;
                    immutable fc = blocks[child].fenceChar;
                    while (p < le && data[p] == fc)
                        ++p;
                    immutable run = p - firstNonspace;
                    while (p < le && isSpaceOrTab(data[p]))
                        ++p;
                    if (p >= le && run >= blocks[child].fenceLength)
                    {
                        finalize(child);
                        tip = blocks[child].parent;
                        return;
                    }
                }
                int i = blocks[child].fenceOffset;
                while (i > 0 && isSpaceOrTab(at(offset)))
                {
                    advance(1, true);
                    --i;
                }
                ok = true;
                break;
            case BlockKind.heading:
                break;
            case BlockKind.thematicBreak:
                ok = true;
                break;
            case BlockKind.paragraph:
                ok = !blank;
                break;
            case BlockKind.document:
                break;
            }
            if (!ok)
            {
                allMatched = false;
                break;
            }
            container = child;
        }
        immutable lastMatched = container;

        // Step 2: start new blocks.
        bool maybeLazy = blocks[oldTip].kind == BlockKind.paragraph;
        while (blocks[container].kind != BlockKind.indentedCode
            && blocks[container].kind != BlockKind.fencedCode)
        {
            findFirstNonspace();
            immutable indented = indent >= 4;
            immutable c = at(firstNonspace);
            int level, fenceLen;
            size_t after;
            bool ordered;
            char delim;
            int start, width;

            if (!indented && c == '>')
            {
                advance(cast(int)(firstNonspace + 1 - offset), false);
                if (isSpaceOrTab(at(offset)))
                    advance(1, true);
                container = addChild(container, BlockKind.blockQuote);
                maybeLazy = false;
            }
            else if (!indented && c == '#' && scanAtx(level, after))
            {
                advance(cast(int)(after - offset), false);
                container = addChild(container, BlockKind.heading);
                blocks[container].level = cast(ubyte) level;
                break;
            }
            else if (!indented && (c == '`' || c == '~') && scanFence(c, fenceLen))
            {
                immutable fenceOff = cast(int)(firstNonspace - offset);
                advance(cast(int)(firstNonspace + fenceLen - offset), false);
                container = addChild(container, BlockKind.fencedCode);
                blocks[container].fenceChar = c;
                blocks[container].fenceLength = fenceLen;
                blocks[container].fenceOffset = fenceOff;
                break;
            }
            else if (!indented && (c == '=' || c == '-')
                && blocks[container].kind == BlockKind.paragraph && scanSetext(c))
            {
                blocks[container].kind = BlockKind.heading;
                blocks[container].level = c == '=' ? 1 : 2;
                advance(cast(int)(le - offset), false);
                break;
            }
            else if (!indented && (c == '*' || c == '_' || c == '-') && scanThematic(c))
            {
                advance(cast(int)(le - offset), false);
                container = addChild(container, BlockKind.thematicBreak);
                break;
            }
            else if (indent < 4 && parseListMarker(blocks[container].kind == BlockKind.paragraph,
                    ordered, delim, start, width))
            {
                immutable markerOff = indent;
                advance(cast(int)(firstNonspace + width - offset), false);
                immutable sOffset = offset;
                immutable sColumn = column;
                immutable sPartial = partialTab;
                while (column - sColumn <= 5 && isSpaceOrTab(at(offset)))
                    advance(1, true);
                immutable n = column - sColumn;
                int padding;
                if (n >= 5 || n < 1 || offset >= le)
                {
                    padding = width + 1;
                    offset = sOffset;
                    column = sColumn;
                    partialTab = sPartial;
                    if (n > 0)
                        advance(1, true);
                }
                else
                    padding = width + n;

                bool match = false;
                if (blocks[container].kind == BlockKind.list)
                    match = blocks[container].ordered == ordered && blocks[container].marker == delim;
                if (!match)
                {
                    container = addChild(container, BlockKind.list);
                    blocks[container].ordered = ordered;
                    blocks[container].marker = delim;
                    blocks[container].start = start;
                }
                container = addChild(container, BlockKind.item);
                blocks[container].markerOffset = markerOff;
                blocks[container].padding = padding;
                maybeLazy = false;
            }
            else if (indented && !maybeLazy && !blank)
            {
                advance(4, true);
                container = addChild(container, BlockKind.indentedCode);
                break;
            }
            else
                break;
        }

        // Step 3: add the text of the line.
        findFirstNonspace();
        if (blank && blocks[container].lastChild)
            blocks[blocks[container].lastChild].lastLineBlank = true;
        {
            immutable ck = blocks[container].kind;
            blocks[container].lastLineBlank = blank
                && ck != BlockKind.blockQuote && ck != BlockKind.heading
                && ck != BlockKind.thematicBreak && ck != BlockKind.fencedCode
                && !(ck == BlockKind.item && blocks[container].firstChild == 0
                    && blocks[container].line == lineNo);
            for (int a = blocks[container].parent; ; a = blocks[a].parent)
            {
                blocks[a].lastLineBlank = false;
                if (a == 0)
                    break;
            }
        }

        if (!allMatched && container == lastMatched && !blank
            && blocks[oldTip].kind == BlockKind.paragraph)
        {
            addLine(oldTip, le); // lazy continuation
            return;
        }

        while (tip != container)
        {
            finalize(tip);
            tip = blocks[tip].parent;
        }

        immutable ck = blocks[container].kind;
        if (ck == BlockKind.indentedCode || ck == BlockKind.fencedCode)
            addLine(container, le);
        else if (blank)
        {
        }
        else if (ck == BlockKind.heading || ck == BlockKind.paragraph)
        {
            size_t end = le;
            if (ck == BlockKind.heading)
                end = chopClosingHashes();
            advance(cast(int)(firstNonspace - offset), false);
            addLine(container, end < offset ? offset : end);
        }
        else
        {
            immutable p = addChild(container, BlockKind.paragraph);
            advance(cast(int)(firstNonspace - offset), false);
            addLine(p, le);
        }
    }

    /// End of the ATX heading content once the closing `#` sequence is
    /// removed. Works on the whole line, like cmark.
    size_t chopClosingHashes()
    {
        size_t e = le;
        while (e > ls && isWhitespace(data[e - 1]))
            --e;
        immutable lineStart = ls;
        ptrdiff_t n = cast(ptrdiff_t) e - 1;
        immutable orig = n;
        while (n >= cast(ptrdiff_t) lineStart && data[n] == '#')
            --n;
        if (n != orig && n >= cast(ptrdiff_t) lineStart && isSpaceOrTab(data[n]))
        {
            e = n;
            while (e > ls && isWhitespace(data[e - 1]))
                --e;
        }
        return e;
    }
}
