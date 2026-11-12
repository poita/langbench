/**
 * Phase 1 of the Markdown converter: the block structure.
 *
 * This is a line-driven parser in the style of the CommonMark reference
 * implementation.  Each line is matched against the chain of open blocks,
 * new blocks are opened, and the rest of the line is added to the innermost
 * open leaf block.
 */
module sitegen.markdown.blocks;

import std.array : appender;
import std.string : indexOf;
import sitegen.markdown.ast;
import sitegen.markdown.entities;

private enum codeIndent = 4;

/**
 * Parses `input` into a tree of blocks.
 *
 * The paragraphs and headings of the returned tree still hold raw text in
 * their `content`; `Block.inlines` is not yet filled in.
 *
 * Params:
 *   input = the Markdown document (UTF-8, LF line endings)
 * Returns: the document block.
 */
Block parseBlocks(string input)
{
    auto p = new BlockParser;
    return p.parse(input);
}

private final class BlockParser
{
    Block root;
    Block tip; // the innermost open block ("current" in cmark)
    size_t lineNumber;

    string line;
    size_t offset;
    size_t column;
    bool partiallyConsumedTab;

    // Results of findNonspace().
    size_t nextNonspace;
    size_t nextNonspaceColumn;
    size_t indent;
    bool blank;

    Block parse(string input)
    {
        root = new Block(BlockKind.document, 0);
        tip = root;
        size_t pos = 0;
        while (pos < input.length)
        {
            auto nl = input[pos .. $].indexOf('\n');
            if (nl < 0)
            {
                processLine(input[pos .. $]);
                break;
            }
            processLine(input[pos .. pos + nl]);
            pos += nl + 1;
        }
        while (tip !is root)
            tip = finalize(tip);
        finalize(root);
        return root;
    }

    /// The character at index `i` of the line; the line terminator is `\n`.
    char peek(size_t i) const pure nothrow @nogc
    {
        return i < line.length ? line[i] : '\n';
    }

    void findNonspace()
    {
        size_t i = offset;
        size_t col = column;
        while (i < line.length)
        {
            const c = line[i];
            if (c == ' ')
            {
                i++;
                col++;
            }
            else if (c == '\t')
            {
                i++;
                col += 4 - col % 4;
            }
            else
                break;
        }
        nextNonspace = i;
        nextNonspaceColumn = col;
        indent = col - column;
        blank = i >= line.length;
    }

    /// Advances the offset by `count` characters, or by `count` columns if
    /// `columns` is set (a tab may then be only partially consumed).
    void advanceOffset(size_t count, bool columns)
    {
        while (count > 0 && offset < line.length)
        {
            const c = line[offset];
            if (c == '\t')
            {
                const charsToTab = 4 - column % 4;
                if (columns)
                {
                    partiallyConsumedTab = charsToTab > count;
                    const advance = partiallyConsumedTab ? count : charsToTab;
                    column += advance;
                    if (!partiallyConsumedTab) offset++;
                    count -= advance;
                }
                else
                {
                    partiallyConsumedTab = false;
                    column += charsToTab;
                    offset++;
                    count--;
                }
            }
            else
            {
                partiallyConsumedTab = false;
                offset++;
                column++;
                count--;
            }
        }
    }

    /// Appends the rest of the line to the content of `b`.
    void addLine(Block b)
    {
        if (partiallyConsumedTab)
        {
            offset++;
            const n = 4 - column % 4;
            foreach (_; 0 .. n) b.content.put(' ');
        }
        if (offset < line.length) b.content.put(line[offset .. $]);
        b.content.put('\n');
    }

    // ------------------------------------------------------------------
    // Closing blocks
    // ------------------------------------------------------------------

    /// Closes `b` and returns its parent.
    Block finalize(Block b)
    {
        auto parent = b.parent;
        b.open = false;
        final switch (b.kind)
        {
            case BlockKind.codeBlock:
                finalizeCode(b);
                break;
            case BlockKind.list:
                finalizeList(b);
                break;
            case BlockKind.document, BlockKind.blockQuote, BlockKind.item,
                BlockKind.paragraph, BlockKind.heading, BlockKind.thematicBreak:
                break;
        }
        return parent;
    }

    void finalizeCode(Block b)
    {
        auto data = b.content.data;
        if (b.fenced)
        {
            // The first line of the content is the info string.
            size_t nl = 0;
            while (nl < data.length && data[nl] != '\n') nl++;
            auto raw = data[0 .. nl].idup;
            b.info = unescapeBackslashes(trimAscii(decodeEntities(raw)));
            auto rest = nl + 1 < data.length ? data[nl + 1 .. $].idup : "";
            b.content.clear();
            b.content.put(rest);
        }
        else
        {
            // Remove trailing blank lines, then add one newline.
            ptrdiff_t i = cast(ptrdiff_t) data.length - 1;
            while (i >= 0 && (data[i] == ' ' || data[i] == '\t' || data[i] == '\n'))
                i--;
            if (i < 0)
            {
                b.content.clear();
            }
            else
            {
                size_t cut = i;
                while (cut < data.length && data[cut] != '\n') cut++;
                auto kept = data[0 .. cut].idup;
                b.content.clear();
                b.content.put(kept);
            }
            b.content.put('\n');
        }
    }

    /// cmark's `S_ends_with_blank_line`, including its memoisation.
    static bool endsWithBlankLine(Block node)
    {
        Block cur = node;
        while (cur !is null)
        {
            if (cur.lastLineChecked) return cur.lastLineBlank;
            cur.lastLineChecked = true;
            if ((cur.kind == BlockKind.list || cur.kind == BlockKind.item) && cur.children.length)
                cur = cur.lastChild;
            else
                return cur.lastLineBlank;
        }
        return false;
    }

    static void finalizeList(Block list)
    {
        list.tight = true;
        foreach (i, item; list.children)
        {
            const itemHasNext = i + 1 < list.children.length;
            if (item.lastLineBlank && itemHasNext)
            {
                list.tight = false;
                break;
            }
            foreach (j, sub; item.children)
            {
                const subHasNext = j + 1 < item.children.length;
                if ((itemHasNext || subHasNext) && endsWithBlankLine(sub))
                {
                    list.tight = false;
                    break;
                }
            }
            if (!list.tight) break;
        }
    }

    static bool canContain(Block parent, BlockKind child)
    {
        final switch (parent.kind)
        {
            case BlockKind.document, BlockKind.blockQuote, BlockKind.item:
                return child != BlockKind.item;
            case BlockKind.list:
                return child == BlockKind.item;
            case BlockKind.paragraph, BlockKind.heading, BlockKind.thematicBreak,
                BlockKind.codeBlock:
                return false;
        }
    }

    Block addChild(Block parent, BlockKind kind)
    {
        while (!canContain(parent, kind))
            parent = finalize(parent);
        auto child = new Block(kind, lineNumber);
        child.parent = parent;
        parent.children ~= child;
        return child;
    }

    // ------------------------------------------------------------------
    // Processing a line
    // ------------------------------------------------------------------

    void processLine(string l)
    {
        lineNumber++;
        line = l;
        offset = 0;
        column = 0;
        partiallyConsumedTab = false;

        bool allMatched;
        bool stop;
        Block lastMatched = checkOpenBlocks(allMatched, stop);
        if (stop) return;
        Block container = lastMatched;
        openNewBlocks(container, allMatched);
        addTextToContainer(container, lastMatched);
    }

    /// Step 1: walks down the open blocks that the line continues.
    Block checkOpenBlocks(out bool allMatched, out bool stop)
    {
        Block container = root;
        stop = false;
        allMatched = false;
        while (container.lastChild !is null && container.lastChild.open)
        {
            container = container.lastChild;
            findNonspace();
            final switch (container.kind)
            {
                case BlockKind.blockQuote:
                    if (!parseBlockQuotePrefix()) goto done;
                    break;
                case BlockKind.item:
                    if (!parseItemPrefix(container)) goto done;
                    break;
                case BlockKind.codeBlock:
                    bool cont = true;
                    const ok = parseCodePrefix(container, cont);
                    if (!cont)
                    {
                        stop = true;
                        return container;
                    }
                    if (!ok) goto done;
                    break;
                case BlockKind.heading:
                    goto done;
                case BlockKind.paragraph:
                    if (blank) goto done;
                    break;
                case BlockKind.document, BlockKind.list, BlockKind.thematicBreak:
                    break;
            }
        }
        allMatched = true;
    done:
        if (!allMatched) container = container.parent;
        return container;
    }

    bool parseBlockQuotePrefix()
    {
        if (indent <= 3 && peek(nextNonspace) == '>' && nextNonspace < line.length)
        {
            advanceOffset(indent + 1, true);
            if (isSpaceOrTab(peek(offset)) && offset < line.length) advanceOffset(1, true);
            return true;
        }
        return false;
    }

    bool parseItemPrefix(Block container)
    {
        const need = cast(size_t)(container.markerOffset + container.padding);
        if (indent >= need)
        {
            advanceOffset(need, true);
            return true;
        }
        if (blank && container.children.length > 0)
        {
            advanceOffset(nextNonspace - offset, false);
            return true;
        }
        return false;
    }

    bool parseCodePrefix(Block container, ref bool shouldContinue)
    {
        if (!container.fenced)
        {
            if (indent >= codeIndent)
            {
                advanceOffset(codeIndent, true);
                return true;
            }
            if (blank)
            {
                advanceOffset(nextNonspace - offset, false);
                return true;
            }
            return false;
        }
        // Fenced code: look for the closing fence.
        size_t matched = 0;
        if (indent <= 3 && nextNonspace < line.length && line[nextNonspace] == container.fenceChar)
        {
            size_t i = nextNonspace;
            while (i < line.length && line[i] == container.fenceChar) i++;
            const runLen = i - nextNonspace;
            size_t j = i;
            while (j < line.length && isSpaceOrTab(line[j])) j++;
            if (j >= line.length && runLen >= 3) matched = runLen;
        }
        if (matched >= cast(size_t) container.fenceLength && matched > 0)
        {
            shouldContinue = false;
            advanceOffset(matched, false);
            tip = finalize(container);
            return true;
        }
        int i = container.fenceOffset;
        while (i > 0 && offset < line.length && isSpaceOrTab(line[offset]))
        {
            advanceOffset(1, true);
            i--;
        }
        return true;
    }

    /// Step 2: opens the blocks that start on this line.
    void openNewBlocks(ref Block container, bool allMatched)
    {
        bool maybeLazy = tip.kind == BlockKind.paragraph;
        while (container.kind != BlockKind.codeBlock)
        {
            findNonspace();
            const indented = indent >= codeIndent;
            const c = peek(nextNonspace);
            size_t matched;
            int lev;

            if (!indented && c == '>')
            {
                advanceOffset(nextNonspace + 1 - offset, false);
                if (offset < line.length && isSpaceOrTab(line[offset])) advanceOffset(1, true);
                container = addChild(container, BlockKind.blockQuote);
            }
            else if (!indented && (matched = scanAtxHeadingStart(nextNonspace)) > 0)
            {
                int level = 0;
                size_t k = nextNonspace;
                while (k < line.length && line[k] == '#')
                {
                    level++;
                    k++;
                }
                advanceOffset(nextNonspace + matched - offset, false);
                container = addChild(container, BlockKind.heading);
                container.level = level;
            }
            else if (!indented && (matched = scanOpenCodeFence(nextNonspace)) > 0)
            {
                const fenceAt = nextNonspace;
                container = addChild(container, BlockKind.codeBlock);
                container.fenced = true;
                container.fenceChar = line[fenceAt];
                container.fenceLength = cast(int) matched;
                container.fenceOffset = cast(int)(fenceAt - offset);
                advanceOffset(fenceAt + matched - offset, false);
            }
            else if (!indented && container.kind == BlockKind.paragraph
                && (lev = scanSetextLine(nextNonspace)) > 0)
            {
                container.kind = BlockKind.heading;
                container.level = lev;
                container.setext = true;
                advanceOffset(line.length - offset, false);
            }
            else if (!indented && scanThematicBreak(nextNonspace))
            {
                container = addChild(container, BlockKind.thematicBreak);
                advanceOffset(line.length - offset, false);
            }
            else if (indent < 4 && parseListMarker(container.kind == BlockKind.paragraph))
            {
                openListItem(container);
            }
            else if (indented && !maybeLazy && !blank)
            {
                advanceOffset(codeIndent, true);
                container = addChild(container, BlockKind.codeBlock);
                container.fenced = false;
            }
            else
                break;

            if (container.kind == BlockKind.paragraph || container.kind == BlockKind.heading
                || container.kind == BlockKind.codeBlock)
                break;
            maybeLazy = false;
        }
    }

    // Pending list marker data produced by parseListMarker().
    bool pOrdered;
    char pDelim;
    int pStart;
    size_t pWidth;

    /// Recognises a list marker at `nextNonspace`.
    bool parseListMarker(bool interruptsParagraph)
    {
        size_t pos = nextNonspace;
        const c = peek(pos);
        if (c == '*' || c == '-' || c == '+')
        {
            pos++;
            if (!isSpace(peek(pos))) return false;
            if (interruptsParagraph && restIsBlank(pos)) return false;
            pOrdered = false;
            pDelim = c;
            pStart = 0;
        }
        else if (isDigit(c))
        {
            int start = 0;
            int digits = 0;
            do
            {
                start = start * 10 + (peek(pos) - '0');
                pos++;
                digits++;
            }
            while (digits < 9 && isDigit(peek(pos)));
            const marker = peek(pos);
            if (marker != '.' && marker != ')') return false;
            pos++;
            if (!isSpace(peek(pos))) return false;
            if (interruptsParagraph && (start != 1 || restIsBlank(pos))) return false;
            pOrdered = true;
            pDelim = marker;
            pStart = start;
        }
        else
            return false;
        pWidth = pos - nextNonspace;
        return true;
    }

    bool restIsBlank(size_t pos) const
    {
        while (pos < line.length && isSpaceOrTab(line[pos])) pos++;
        return pos >= line.length;
    }

    void openListItem(ref Block container)
    {
        const markerOffset = cast(int) indent;
        advanceOffset(nextNonspace + pWidth - offset, false);

        const saveTab = partiallyConsumedTab;
        const saveOffset = offset;
        const saveColumn = column;
        while (column - saveColumn <= 5 && offset < line.length && isSpaceOrTab(line[offset]))
            advanceOffset(1, true);
        const i = column - saveColumn;
        int padding;
        if (i >= 5 || i < 1 || offset >= line.length)
        {
            padding = cast(int) pWidth + 1;
            offset = saveOffset;
            column = saveColumn;
            partiallyConsumedTab = saveTab;
            if (i > 0) advanceOffset(1, true);
        }
        else
            padding = cast(int)(pWidth + i);

        const ordered = pOrdered;
        const delim = pDelim;
        const start = pStart;
        if (!(container.kind == BlockKind.list && container.ordered == ordered
                && container.delimiter == delim))
        {
            container = addChild(container, BlockKind.list);
            container.ordered = ordered;
            container.delimiter = delim;
            container.start = start;
        }
        container = addChild(container, BlockKind.item);
        container.ordered = ordered;
        container.delimiter = delim;
        container.markerOffset = markerOffset;
        container.padding = padding;
    }

    // ------------------------------------------------------------------
    // Scanners: each costs what it examines.
    // ------------------------------------------------------------------

    /// Length of `#{1,6}` plus the following spaces/tabs, or 0.
    size_t scanAtxHeadingStart(size_t pos) const
    {
        size_t i = pos;
        while (i < line.length && line[i] == '#') i++;
        const hashes = i - pos;
        if (hashes < 1 || hashes > 6) return 0;
        if (i >= line.length) return hashes;
        if (!isSpaceOrTab(line[i])) return 0;
        while (i < line.length && isSpaceOrTab(line[i])) i++;
        return i - pos;
    }

    /// Length of an opening code fence, or 0.
    size_t scanOpenCodeFence(size_t pos) const
    {
        const c = peek(pos);
        if (c != '`' && c != '~') return 0;
        size_t i = pos;
        while (i < line.length && line[i] == c) i++;
        const n = i - pos;
        if (n < 3) return 0;
        if (c == '`')
        {
            foreach (ch; line[i .. $])
                if (ch == '`') return 0;
        }
        return n;
    }

    /// 1 for a `=` underline, 2 for a `-` underline, else 0.
    int scanSetextLine(size_t pos) const
    {
        const c = peek(pos);
        if (c != '=' && c != '-') return 0;
        size_t i = pos;
        while (i < line.length && line[i] == c) i++;
        while (i < line.length && isSpaceOrTab(line[i])) i++;
        if (i < line.length) return 0;
        return c == '=' ? 1 : 2;
    }

    bool scanThematicBreak(size_t pos) const
    {
        const c = peek(pos);
        if (c != '*' && c != '_' && c != '-') return false;
        size_t count = 0;
        foreach (ch; line[pos .. $])
        {
            if (ch == c)
                count++;
            else if (!isSpaceOrTab(ch))
                return false;
        }
        return count >= 3;
    }

    // ------------------------------------------------------------------
    // Step 3: adding the text of the line
    // ------------------------------------------------------------------

    void addTextToContainer(Block container, Block lastMatched)
    {
        findNonspace();
        if (blank && container.lastChild !is null)
            container.lastChild.lastLineBlank = true;

        const kind = container.kind;
        const lastLineBlank = blank && kind != BlockKind.blockQuote && kind != BlockKind.heading
            && kind != BlockKind.thematicBreak && !(kind == BlockKind.codeBlock && container.fenced)
            && !(kind == BlockKind.item && container.children.length == 0
                && container.startLine == lineNumber);
        container.lastLineBlank = lastLineBlank;
        for (auto t = container.parent; t !is null; t = t.parent)
            t.lastLineBlank = false;

        if (tip !is lastMatched && container is lastMatched && !blank
            && tip.kind == BlockKind.paragraph)
        {
            // Lazy continuation line.
            addLine(tip);
            return;
        }
        while (tip !is lastMatched)
            tip = finalize(tip);

        if (kind == BlockKind.codeBlock)
        {
            addLine(container);
        }
        else if (blank)
        {
            // nothing to add
        }
        else if (kind == BlockKind.paragraph || kind == BlockKind.heading)
        {
            if (kind == BlockKind.heading && !container.setext) chopTrailingHashes();
            advanceOffset(nextNonspace - offset, false);
            addLine(container);
        }
        else
        {
            container = addChild(container, BlockKind.paragraph);
            advanceOffset(nextNonspace - offset, false);
            addLine(container);
        }
        tip = container;
    }

    /// Removes the optional closing sequence of an ATX heading from the
    /// rest of the line.
    void chopTrailingHashes()
    {
        size_t end = line.length;
        while (end > offset && isSpace(line[end - 1])) end--;
        size_t n = end;
        while (n > offset && line[n - 1] == '#') n--;
        if (n != end && (n == offset || isSpaceOrTab(line[n - 1])))
        {
            end = n;
            while (end > offset && isSpace(line[end - 1])) end--;
        }
        line = line[0 .. end];
    }
}

unittest
{
    auto doc = parseBlocks("# Title\n\n- a\n- b\n");
    assert(doc.children.length == 2);
    assert(doc.children[0].kind == BlockKind.heading);
    assert(doc.children[0].level == 1);
    assert(doc.children[1].kind == BlockKind.list);
    assert(doc.children[1].tight);
    assert(doc.children[1].children.length == 2);
}

unittest
{
    auto doc = parseBlocks("- a\n\n- b\n");
    assert(!doc.children[0].tight);
}

unittest
{
    auto doc = parseBlocks("```py\nx\n```\n");
    auto code = doc.children[0];
    assert(code.fenced && code.info == "py");
    assert(code.content.data == "x\n");
}
