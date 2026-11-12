/**
 * Phase 1 of the conversion: building the block tree.
 *
 * This is a line-by-line parser in the style of the CommonMark reference
 * implementation (see Appendix A of the specification). Each line is matched
 * against the chain of open blocks, new blocks are opened, and the remainder of
 * the line is added to the innermost open leaf. Scanners only look at the
 * characters they consume, so the cost of a line is proportional to its length
 * plus the nesting depth.
 *
 * Supported: block quotes, lists and items, ATX and setext headings, thematic
 * breaks, indented and fenced code blocks, and paragraphs. HTML blocks and link
 * reference definitions are not recognised.
 */
module commonmark.block;

import commonmark.ast;
import commonmark.text;

/**
 * Parses `markdown` into a block tree.
 *
 * Lines are split at `\n`; a final line without a terminator is still a line.
 *
 * Returns: the document block.
 */
Block parseBlocks(string markdown)
{
    auto parser = BlockParser(markdown);
    return parser.run();
}

private enum tabStop = 4;
private enum codeIndent = 4;

private struct BlockParser
{
    string input;
    Block root;
    Block tip;
    int lineNumber;

    // Per-line state.
    string line;
    int offset;
    int column;
    int firstNonspace;
    int indent;
    bool blank;
    bool partiallyConsumedTab;

    this(string input)
    {
        this.input = input;
    }

    Block run()
    {
        root = new Block(BlockKind.document);
        tip = root;
        size_t pos = 0;
        while (pos < input.length)
        {
            size_t end = pos;
            while (end < input.length && input[end] != '\n')
                ++end;
            processLine(input[pos .. end]);
            pos = end + 1;
        }
        while (tip !is null)
            tip = finalize(tip);
        return root;
    }

    // ---- character access ------------------------------------------------

    /// The character at `i`; the end of the line reads as `\n`.
    char peek(int i) const
    {
        if (i < line.length)
            return line[i];
        return i == line.length ? '\n' : '\0';
    }

    void findFirstNonspace()
    {
        int fn = offset;
        int fnc = column;
        int charsToTab = tabStop - column % tabStop;
        for (;;)
        {
            immutable c = peek(fn);
            if (c == ' ')
            {
                ++fn;
                ++fnc;
                if (--charsToTab == 0)
                    charsToTab = tabStop;
            }
            else if (c == '\t')
            {
                ++fn;
                fnc += charsToTab;
                charsToTab = tabStop;
            }
            else
                break;
        }
        firstNonspace = fn;
        indent = fnc - column;
        blank = peek(fn) == '\n';
    }

    /// Advances `count` characters, or `count` columns when `columns` is set.
    void advance(int count, bool columns)
    {
        while (count > 0 && offset < line.length)
        {
            if (line[offset] == '\t')
            {
                immutable charsToTab = tabStop - column % tabStop;
                if (columns)
                {
                    partiallyConsumedTab = charsToTab > count;
                    immutable adv = partiallyConsumedTab ? count : charsToTab;
                    column += adv;
                    if (!partiallyConsumedTab)
                        ++offset;
                    count -= adv;
                }
                else
                {
                    partiallyConsumedTab = false;
                    column += charsToTab;
                    ++offset;
                    --count;
                }
            }
            else
            {
                partiallyConsumedTab = false;
                ++offset;
                ++column;
                --count;
            }
        }
    }

    // ---- line processing -------------------------------------------------

    void processLine(string ln)
    {
        line = ln;
        offset = 0;
        column = 0;
        firstNonspace = 0;
        indent = 0;
        blank = false;
        partiallyConsumedTab = false;
        ++lineNumber;

        bool allMatched;
        bool stop;
        Block lastMatched = checkOpenBlocks(allMatched, stop);
        if (stop)
            return;
        Block container = lastMatched;
        openNewBlocks(container);
        addText(container, lastMatched);
    }

    /// Step 1: continue the open blocks. Returns the last block that matched.
    Block checkOpenBlocks(out bool allMatched, out bool stop)
    {
        Block cont = root;
        while (cont.lastChild !is null && cont.lastChild.open)
        {
            Block child = cont.lastChild;
            findFirstNonspace();
            final switch (child.kind)
            {
            case BlockKind.blockQuote:
                if (indent <= 3 && peek(firstNonspace) == '>')
                {
                    advance(firstNonspace + 1 - offset, false);
                    if (isSpaceOrTab(peek(offset)))
                        advance(1, true);
                }
                else
                    return cont;
                break;
            case BlockKind.item:
                if (indent >= child.markerOffset + child.padding)
                    advance(child.markerOffset + child.padding, true);
                else if (blank && child.firstChild !is null)
                    advance(firstNonspace - offset, false);
                else
                    return cont;
                break;
            case BlockKind.codeBlock:
                if (child.fenced)
                {
                    if (indent <= 3 && peek(firstNonspace) == child.fenceChar
                        && isClosingFence(child))
                    {
                        tip = finalize(child);
                        stop = true;
                        return cont;
                    }
                    int i = child.fenceOffset;
                    while (i > 0 && isSpaceOrTab(peek(offset)))
                    {
                        advance(1, true);
                        --i;
                    }
                }
                else if (indent >= codeIndent)
                    advance(codeIndent, true);
                else if (blank)
                    advance(firstNonspace - offset, false);
                else
                    return cont;
                break;
            case BlockKind.heading:
                return cont;
            case BlockKind.paragraph:
                if (blank)
                    return cont;
                break;
            case BlockKind.document:
            case BlockKind.list:
            case BlockKind.thematicBreak:
                break;
            }
            cont = child;
        }
        allMatched = true;
        return cont;
    }

    bool isClosingFence(Block b) const
    {
        int i = firstNonspace;
        int n = 0;
        while (peek(i) == b.fenceChar)
        {
            ++i;
            ++n;
        }
        if (n < b.fenceLength)
            return false;
        while (isSpaceOrTab(peek(i)))
            ++i;
        return peek(i) == '\n';
    }

    static bool acceptsLines(BlockKind k)
    {
        return k == BlockKind.paragraph || k == BlockKind.heading || k == BlockKind.codeBlock;
    }

    static bool canContain(BlockKind parent, BlockKind child)
    {
        final switch (parent)
        {
        case BlockKind.document:
        case BlockKind.blockQuote:
        case BlockKind.item:
            return child != BlockKind.item;
        case BlockKind.list:
            return child == BlockKind.item;
        case BlockKind.paragraph:
        case BlockKind.heading:
        case BlockKind.thematicBreak:
        case BlockKind.codeBlock:
            return false;
        }
    }

    Block addChild(Block parent, BlockKind kind)
    {
        while (!canContain(parent.kind, kind))
            parent = finalize(parent);
        auto b = new Block(kind);
        b.startLine = lineNumber;
        parent.appendChild(b);
        return b;
    }

    /// Step 2: open new blocks at the current position.
    void openNewBlocks(ref Block container)
    {
        bool maybeLazy = tip.kind == BlockKind.paragraph;
        while (container.kind != BlockKind.codeBlock)
        {
            findFirstNonspace();
            immutable indented = indent >= codeIndent;
            immutable c = peek(firstNonspace);
            int matched, level;

            if (!indented && c == '>')
            {
                advance(firstNonspace + 1 - offset, false);
                if (isSpaceOrTab(peek(offset)))
                    advance(1, true);
                container = addChild(container, BlockKind.blockQuote);
            }
            else if (!indented && c == '#' && (matched = scanAtxStart(firstNonspace, level)) != 0)
            {
                advance(firstNonspace + matched - offset, false);
                container = addChild(container, BlockKind.heading);
                container.level = level;
            }
            else if (!indented && (c == '`' || c == '~') && (matched = scanOpenFence(firstNonspace)) != 0)
            {
                immutable fenceOffset = firstNonspace - offset;
                container = addChild(container, BlockKind.codeBlock);
                container.fenced = true;
                container.fenceChar = c;
                container.fenceLength = matched;
                container.fenceOffset = fenceOffset;
                advance(firstNonspace + matched - offset, false);
            }
            else if (!indented && container.kind == BlockKind.paragraph
                && (c == '=' || c == '-') && (level = scanSetextLine(firstNonspace)) != 0)
            {
                container.kind = BlockKind.heading;
                container.level = level;
                container.setext = true;
                advance(cast(int) line.length - offset, false);
            }
            else if (!indented && (c == '*' || c == '_' || c == '-') && scanThematicBreak(firstNonspace))
            {
                container = addChild(container, BlockKind.thematicBreak);
                advance(cast(int) line.length - offset, false);
            }
            else if (indent < codeIndent && openListItem(container))
            {
                // container updated by openListItem
            }
            else if (indented && !maybeLazy && !blank)
            {
                advance(codeIndent, true);
                container = addChild(container, BlockKind.codeBlock);
            }
            else
                break;

            if (acceptsLines(container.kind))
                break;
            maybeLazy = false;
        }
    }

    /// Tries to start a list item at the first non-space character.
    bool openListItem(ref Block container)
    {
        immutable interrupts = container.kind == BlockKind.paragraph;
        int pos = firstNonspace;
        immutable c = peek(pos);
        bool ordered = false;
        char delimiter;
        int number = 1;
        if (c == '*' || c == '-' || c == '+')
        {
            ++pos;
            delimiter = c;
        }
        else if (isDigit(c))
        {
            int digits = 0;
            number = 0;
            do
            {
                number = number * 10 + (peek(pos) - '0');
                ++pos;
                ++digits;
            }
            while (digits < 9 && isDigit(peek(pos)));
            if (interrupts && number != 1)
                return false;
            immutable d = peek(pos);
            if (d != '.' && d != ')')
                return false;
            ++pos;
            ordered = true;
            delimiter = d;
        }
        else
            return false;

        if (!isSpace(peek(pos)))
            return false;
        if (interrupts)
        {
            int i = pos;
            while (isSpaceOrTab(peek(i)))
                ++i;
            if (peek(i) == '\n')
                return false;
        }
        immutable matched = pos - firstNonspace;
        immutable markerOffset = indent;

        advance(firstNonspace + matched - offset, false);
        immutable savedTab = partiallyConsumedTab;
        immutable savedOffset = offset;
        immutable savedColumn = column;
        while (column - savedColumn <= 5 && isSpaceOrTab(peek(offset)))
            advance(1, true);
        immutable n = column - savedColumn;
        int padding;
        if (n >= 5 || n < 1 || peek(offset) == '\n')
        {
            padding = matched + 1;
            offset = savedOffset;
            column = savedColumn;
            partiallyConsumedTab = savedTab;
            if (n > 0)
                advance(1, true);
        }
        else
            padding = matched + n;

        if (container.kind != BlockKind.list || container.ordered != ordered
            || container.delimiter != delimiter)
        {
            container = addChild(container, BlockKind.list);
            container.ordered = ordered;
            container.delimiter = delimiter;
            container.start = number;
        }
        container = addChild(container, BlockKind.item);
        container.ordered = ordered;
        container.delimiter = delimiter;
        container.markerOffset = markerOffset;
        container.padding = padding;
        return true;
    }

    // ---- scanners --------------------------------------------------------

    /// `#{1,6}` followed by spaces/tabs or the end of the line. Returns the
    /// number of bytes including the whitespace, or 0.
    int scanAtxStart(int pos, out int level)
    {
        int i = pos;
        while (peek(i) == '#')
            ++i;
        level = i - pos;
        if (level < 1 || level > 6)
            return 0;
        immutable c = peek(i);
        if (c == '\n')
            return i - pos;
        if (!isSpaceOrTab(c))
            return 0;
        while (isSpaceOrTab(peek(i)))
            ++i;
        return i - pos;
    }

    /// Three or more backticks (with no backtick later on the line) or tildes.
    /// Returns the length of the fence run, or 0.
    int scanOpenFence(int pos)
    {
        immutable c = peek(pos);
        int i = pos;
        while (peek(i) == c)
            ++i;
        immutable n = i - pos;
        if (n < 3)
            return 0;
        if (c == '`')
        {
            for (; i < line.length; ++i)
                if (line[i] == '`')
                    return 0;
        }
        return n;
    }

    /// A run of `=` or `-` followed only by spaces/tabs. Returns the heading
    /// level, or 0.
    int scanSetextLine(int pos)
    {
        immutable c = peek(pos);
        int i = pos;
        while (peek(i) == c)
            ++i;
        while (isSpaceOrTab(peek(i)))
            ++i;
        if (peek(i) != '\n')
            return 0;
        return c == '=' ? 1 : 2;
    }

    /// Three or more of the same `*`, `_` or `-`, with only spaces/tabs between.
    bool scanThematicBreak(int pos)
    {
        immutable c = peek(pos);
        int count = 0;
        for (int i = pos; ; ++i)
        {
            immutable d = peek(i);
            if (d == c)
                ++count;
            else if (d == '\n')
                return count >= 3;
            else if (!isSpaceOrTab(d))
                return false;
        }
    }

    // ---- step 3 ----------------------------------------------------------

    void addLine(Block b)
    {
        if (partiallyConsumedTab)
        {
            ++offset;
            immutable n = tabStop - column % tabStop;
            foreach (_; 0 .. n)
                b.buf ~= ' ';
        }
        if (offset < line.length)
            b.buf ~= line[offset .. $];
        b.buf ~= '\n';
    }

    void addText(Block container, Block lastMatched)
    {
        findFirstNonspace();
        if (blank && container.lastChild !is null)
            container.lastChild.lastLineBlank = true;

        immutable k = container.kind;
        container.lastLineBlank = blank && k != BlockKind.blockQuote && k != BlockKind.heading
            && k != BlockKind.thematicBreak && !(k == BlockKind.codeBlock && container.fenced)
            && !(k == BlockKind.item && container.firstChild is null
                && container.startLine == lineNumber);
        for (Block p = container.parent; p !is null; p = p.parent)
            p.lastLineBlank = false;

        if (tip !is lastMatched && container is lastMatched && !blank
            && tip.kind == BlockKind.paragraph)
        {
            addLine(tip);
            return;
        }
        while (tip !is lastMatched)
            tip = finalize(tip);

        if (k == BlockKind.codeBlock)
            addLine(container);
        else if (blank)
        {
        }
        else if (acceptsLines(k))
        {
            if (k == BlockKind.heading && !container.setext)
                addAtxContent(container);
            else
            {
                advance(firstNonspace - offset, false);
                addLine(container);
            }
        }
        else
        {
            container = addChild(container, BlockKind.paragraph);
            advance(firstNonspace - offset, false);
            addLine(container);
        }
        tip = container;
    }

    /// Adds the rest of the line as ATX heading content, dropping the closing
    /// sequence of `#`s.
    void addAtxContent(Block h)
    {
        int end = cast(int) line.length;
        while (end > 0 && isSpace(line[end - 1]))
            --end;
        int n = end - 1;
        immutable orig = n;
        while (n >= 0 && line[n] == '#')
            --n;
        if (n != orig && n >= 0 && isSpaceOrTab(line[n]))
        {
            end = n;
            while (end > 0 && isSpace(line[end - 1]))
                --end;
        }
        advance(firstNonspace - offset, false);
        if (end > offset)
            h.buf ~= line[offset .. end];
    }

    // ---- finalisation ----------------------------------------------------

    /// Closes `b` and returns its parent.
    Block finalize(Block b)
    {
        Block parent = b.parent;
        if (!b.open)
            return parent;
        b.open = false;
        final switch (b.kind)
        {
        case BlockKind.paragraph:
        case BlockKind.heading:
            b.text = takeText(b);
            break;
        case BlockKind.codeBlock:
            finalizeCode(b);
            break;
        case BlockKind.list:
            b.tight = isTight(b);
            break;
        case BlockKind.document:
        case BlockKind.blockQuote:
        case BlockKind.item:
        case BlockKind.thematicBreak:
            break;
        }
        return parent;
    }

    static string takeText(Block b)
    {
        auto t = (() @trusted => cast(string) b.buf)();
        b.buf = null;
        return t;
    }

    static void finalizeCode(Block b)
    {
        string content = takeText(b);
        if (b.fenced)
        {
            size_t nl = 0;
            while (nl < content.length && content[nl] != '\n')
                ++nl;
            b.info = cleanString(trim(content[0 .. nl]).idup);
            b.text = nl < content.length ? content[nl + 1 .. $] : "";
        }
        else
        {
            size_t i = content.length;
            while (i > 0 && isSpace(content[i - 1]))
                --i;
            if (i == 0)
                b.text = "\n";
            else
            {
                while (i < content.length && content[i] != '\n')
                    ++i;
                b.text = content[0 .. i] ~ "\n";
            }
        }
    }

    // ---- list tightness --------------------------------------------------

    static bool endsWithBlankLine(Block b)
    {
        if (b.lastLineChecked)
            return b.lastLineBlank;
        b.lastLineChecked = true;
        if ((b.kind == BlockKind.list || b.kind == BlockKind.item) && b.lastChild !is null)
            return endsWithBlankLine(b.lastChild);
        return b.lastLineBlank;
    }

    static bool isTight(Block list)
    {
        for (Block item = list.firstChild; item !is null; item = item.next)
        {
            if (item.lastLineBlank && item.next !is null)
                return false;
            for (Block sub = item.firstChild; sub !is null; sub = sub.next)
                if ((item.next !is null || sub.next !is null) && endsWithBlankLine(sub))
                    return false;
        }
        return true;
    }
}

version (unittest)
{
    private string dump(Block b)
    {
        import std.conv : to;
        import std.format : format;

        string s;
        final switch (b.kind)
        {
        case BlockKind.document: s = "doc"; break;
        case BlockKind.blockQuote: s = "bq"; break;
        case BlockKind.list:
            s = format("list(%s%s)", b.tight ? "tight" : "loose", b.ordered ? ",ol" ~ b.start.to!string : "");
            break;
        case BlockKind.item: s = "item"; break;
        case BlockKind.paragraph: s = format("p[%s]", trimRight(b.text)); break;
        case BlockKind.heading: s = format("h%d[%s]", b.level, trimRight(b.text)); break;
        case BlockKind.thematicBreak: s = "hr"; break;
        case BlockKind.codeBlock: s = format("code(%s)[%s]", b.info, b.text); break;
        }
        if (b.firstChild !is null)
        {
            s ~= "{";
            for (Block c = b.firstChild; c !is null; c = c.next)
                s ~= dump(c) ~ (c.next !is null ? "," : "");
            s ~= "}";
        }
        return s;
    }
}

unittest
{
    assert(dump(parseBlocks("")) == "doc");
    assert(dump(parseBlocks("# Hi #\n")) == "doc{h1[Hi]}");
    assert(dump(parseBlocks("a\nb\n---\n")) == "doc{h2[a\nb]}");
    assert(dump(parseBlocks("a\n\nb")) == "doc{p[a],p[b]}");
    assert(dump(parseBlocks("    x\n\n    y\n")) == "doc{code()[x\n\ny\n]}");
    assert(dump(parseBlocks("```py\nx\n```")) == "doc{code(py)[x\n]}");
}

unittest
{
    assert(dump(parseBlocks("- a\n- b\n")) == "doc{list(tight){item{p[a]},item{p[b]}}}");
    assert(dump(parseBlocks("- a\n\n- b\n")) == "doc{list(loose){item{p[a]},item{p[b]}}}");
    assert(dump(parseBlocks("3. a\n4. b\n")) == "doc{list(tight,ol3){item{p[a]},item{p[b]}}}");
    assert(dump(parseBlocks("> a\nb\n")) == "doc{bq{p[a\nb]}}");
    assert(dump(parseBlocks("* a\n+ b\n")) == "doc{list(tight){item{p[a]}},list(tight){item{p[b]}}}");
}

unittest
{
    // Tabs: a tab after a list marker is partially consumed.
    assert(dump(parseBlocks("-\tfoo\n")) == "doc{list(tight){item{p[foo]}}}");
    assert(dump(parseBlocks("- foo\n\n\t\tbar\n")) == "doc{list(loose){item{p[foo],code()[  bar\n]}}}");
}
