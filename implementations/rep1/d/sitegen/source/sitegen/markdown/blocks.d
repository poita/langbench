/// Phase 1 of the Markdown conversion: the line-driven block structure parser.
module sitegen.markdown.blocks;

import sitegen.markdown.node;
import sitegen.markdown.text;

/// Parses a document into a tree of block nodes whose leaf blocks
/// (paragraphs, headings, code blocks) hold their raw text in `Node.content`.
///
/// The algorithm follows the reference implementation: for every line the
/// chain of open blocks is walked to see which continue, new blocks are
/// started, and the rest of the line is added to the innermost open leaf.
final class BlockParser
{
    private Node root;
    private Node current; // the tip: innermost open block
    private int lineNumber;

    // state of the line being processed
    private const(char)[] line;
    private int offset;
    private int column;
    private bool partiallyConsumedTab;
    private int firstNonspace;
    private int firstNonspaceColumn;
    private int indent;
    private bool blank;

    /// Build the block tree for `src`.
    Node parse(string src)
    {
        root = new Node(NodeKind.document);
        current = root;
        lineNumber = 0;
        size_t pos = 0;
        while (pos < src.length)
        {
            size_t e = pos;
            while (e < src.length && src[e] != '\n')
                ++e;
            processLine(src[pos .. e]);
            pos = e + 1;
        }
        while (current !is root)
            current = finalize(current);
        finalize(root);
        return root;
    }

    // ------------------------------------------------------------------
    // line scanning helpers

    private char peek(int i) const pure nothrow @safe @nogc
    {
        return i >= 0 && i < line.length ? line[i] : '\n';
    }

    private void findFirstNonspace() pure nothrow @safe @nogc
    {
        int fn = offset;
        int fnc = column;
        int charsToTab = 4 - (column % 4);
        while (fn < line.length)
        {
            immutable c = line[fn];
            if (c == ' ')
            {
                ++fn;
                ++fnc;
                if (--charsToTab == 0)
                    charsToTab = 4;
            }
            else if (c == '\t')
            {
                ++fn;
                fnc += charsToTab;
                charsToTab = 4;
            }
            else
                break;
        }
        firstNonspace = fn;
        firstNonspaceColumn = fnc;
        indent = fnc - column;
        blank = fn >= line.length;
    }

    private void advanceOffset(int count, bool columns) pure nothrow @safe @nogc
    {
        while (count > 0 && offset < line.length)
        {
            immutable c = line[offset];
            if (c == '\t')
            {
                immutable charsToTab = 4 - (column % 4);
                if (columns)
                {
                    partiallyConsumedTab = charsToTab > count;
                    immutable adv = charsToTab > count ? count : charsToTab;
                    column += adv;
                    offset += partiallyConsumedTab ? 0 : 1;
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

    /// Append the rest of the line (up to `end`) plus LF to the leaf `n`.
    private void addLine(Node n, int end = -1)
    {
        if (partiallyConsumedTab)
        {
            ++offset;
            immutable spaces = 4 - (column % 4);
            foreach (_; 0 .. spaces)
                n.content ~= ' ';
        }
        if (end < 0)
            end = cast(int) line.length;
        if (offset < end)
            n.content ~= line[offset .. end];
        n.content ~= '\n';
    }

    // ------------------------------------------------------------------
    // per-line processing

    private void processLine(const(char)[] ln)
    {
        line = ln;
        ++lineNumber;
        offset = 0;
        column = 0;
        blank = false;
        partiallyConsumedTab = false;

        bool allMatched;
        Node container = checkOpenBlocks(allMatched);
        if (container is null)
            return;
        Node lastMatched = container;
        openNewBlocks(container, allMatched);
        addTextToContainer(container, lastMatched);
    }

    /// Step 1: which open blocks does this line continue? Returns the last
    /// matched block, or null if the line was fully consumed (closing fence).
    private Node checkOpenBlocks(out bool allMatched)
    {
        allMatched = false;
        Node container = root;
        while (container.lastChild !is null && container.lastChild.open)
        {
            Node child = container.lastChild;
            findFirstNonspace();
            bool matches;
            bool lineDone;
            final switch (child.kind)
            {
            case NodeKind.blockQuote:
                matches = parseBlockQuotePrefix();
                break;
            case NodeKind.item:
                matches = parseItemPrefix(child);
                break;
            case NodeKind.codeBlock:
                matches = parseCodeBlockPrefix(child, lineDone);
                if (lineDone)
                    return null;
                break;
            case NodeKind.heading:
                matches = false;
                break;
            case NodeKind.paragraph:
                matches = !blank;
                break;
            case NodeKind.list:
            case NodeKind.thematicBreak:
                matches = true;
                break;
            case NodeKind.document:
            case NodeKind.text:
            case NodeKind.softBreak:
            case NodeKind.lineBreak:
            case NodeKind.code:
            case NodeKind.emph:
            case NodeKind.strong:
            case NodeKind.link:
            case NodeKind.image:
                matches = false;
                break;
            }
            if (!matches)
                return container;
            container = child;
        }
        allMatched = true;
        return container;
    }

    private bool parseBlockQuotePrefix()
    {
        if (indent <= 3 && peek(firstNonspace) == '>')
        {
            advanceOffset(firstNonspace + 1 - offset, false);
            if (isSpaceOrTab(peek(offset)) && offset < line.length)
                advanceOffset(1, true);
            return true;
        }
        return false;
    }

    private bool parseItemPrefix(Node item)
    {
        if (indent >= item.markerOffset + item.padding)
        {
            advanceOffset(item.markerOffset + item.padding, true);
            return true;
        }
        if (blank && item.firstChild !is null)
        {
            advanceOffset(firstNonspace - offset, false);
            return true;
        }
        return false;
    }

    private bool parseCodeBlockPrefix(Node code, out bool lineDone)
    {
        lineDone = false;
        if (!code.fenced)
        {
            if (indent >= 4)
            {
                advanceOffset(4, true);
                return true;
            }
            if (blank)
            {
                advanceOffset(firstNonspace - offset, false);
                return true;
            }
            return false;
        }
        if (indent <= 3 && peek(firstNonspace) == code.fenceChar)
        {
            int i = firstNonspace;
            while (i < line.length && line[i] == code.fenceChar)
                ++i;
            immutable run = i - firstNonspace;
            int j = i;
            while (j < line.length && isSpaceOrTab(line[j]))
                ++j;
            if (j >= line.length && run >= code.fenceLength)
            {
                lineDone = true;
                current = finalize(code);
                return false;
            }
        }
        int i = code.fenceOffset;
        while (i > 0 && offset < line.length && isSpaceOrTab(line[offset]))
        {
            advanceOffset(1, true);
            --i;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // step 2: block starts

    private static bool acceptsLines(NodeKind k) pure nothrow @safe @nogc
    {
        return k == NodeKind.paragraph || k == NodeKind.heading || k == NodeKind.codeBlock;
    }

    private static bool canContain(Node parent, NodeKind child) pure nothrow @safe @nogc
    {
        switch (parent.kind)
        {
        case NodeKind.document:
        case NodeKind.blockQuote:
        case NodeKind.item:
            return child != NodeKind.item;
        case NodeKind.list:
            return child == NodeKind.item;
        default:
            return false;
        }
    }

    private Node addChild(Node parent, NodeKind kind)
    {
        while (!canContain(parent, kind))
            parent = finalize(parent);
        auto child = new Node(kind);
        child.startLine = lineNumber;
        parent.appendChild(child);
        return child;
    }

    private void openNewBlocks(ref Node container, bool allMatched)
    {
        bool maybeLazy = current.kind == NodeKind.paragraph;
        while (container.kind != NodeKind.codeBlock)
        {
            findFirstNonspace();
            immutable indented = indent >= 4;
            immutable c = peek(firstNonspace);
            int level, matched;

            if (!indented && c == '>')
            {
                advanceOffset(firstNonspace + 1 - offset, false);
                if (offset < line.length && isSpaceOrTab(line[offset]))
                    advanceOffset(1, true);
                container = addChild(container, NodeKind.blockQuote);
            }
            else if (!indented && c == '#' && (matched = scanAtxStart(level)) > 0)
            {
                advanceOffset(firstNonspace + matched - offset, false);
                container = addChild(container, NodeKind.heading);
                container.level = level;
            }
            else if (!indented && (c == '`' || c == '~') && (matched = scanOpenFence()) > 0)
            {
                auto code = addChild(container, NodeKind.codeBlock);
                code.fenced = true;
                code.fenceChar = c;
                code.fenceLength = matched;
                code.fenceOffset = firstNonspace - offset;
                advanceOffset(firstNonspace + matched - offset, false);
                container = code;
            }
            else if (!indented && container.kind == NodeKind.paragraph
                    && (c == '=' || c == '-') && (level = scanSetextUnderline()) > 0)
            {
                container.kind = NodeKind.heading;
                container.level = level;
                container.setext = true;
                advanceOffset(cast(int) line.length - offset, false);
            }
            else if (!indented && (c == '*' || c == '_' || c == '-') && scanThematicBreak())
            {
                container = addChild(container, NodeKind.thematicBreak);
                advanceOffset(cast(int) line.length - offset, false);
            }
            else if (indent < 4 && openListItem(container))
            {
                // container updated by openListItem
            }
            else if (indented && !maybeLazy && !blank)
            {
                advanceOffset(4, true);
                container = addChild(container, NodeKind.codeBlock);
            }
            else
                break;

            if (acceptsLines(container.kind))
                break;
            maybeLazy = false;
        }
    }

    /// `#{1,6}` followed by spaces/tabs or end of line; returns the match length
    /// including the trailing blanks.
    private int scanAtxStart(out int level) const pure nothrow @safe @nogc
    {
        int i = firstNonspace;
        while (i < line.length && line[i] == '#')
            ++i;
        level = i - firstNonspace;
        if (level < 1 || level > 6)
            return 0;
        if (i < line.length && !isSpaceOrTab(line[i]))
            return 0;
        while (i < line.length && isSpaceOrTab(line[i]))
            ++i;
        return i - firstNonspace;
    }

    /// Opening code fence: returns the fence length or 0.
    private int scanOpenFence() const pure nothrow @safe @nogc
    {
        immutable c = line[firstNonspace];
        int i = firstNonspace;
        while (i < line.length && line[i] == c)
            ++i;
        immutable run = i - firstNonspace;
        if (run < 3)
            return 0;
        if (c == '`')
            foreach (k; i .. line.length)
                if (line[k] == '`')
                    return 0;
        return run;
    }

    private int scanSetextUnderline() const pure nothrow @safe @nogc
    {
        immutable c = line[firstNonspace];
        int i = firstNonspace;
        while (i < line.length && line[i] == c)
            ++i;
        while (i < line.length && isSpaceOrTab(line[i]))
            ++i;
        if (i < line.length)
            return 0;
        return c == '=' ? 1 : 2;
    }

    private bool scanThematicBreak() const pure nothrow @safe @nogc
    {
        immutable c = line[firstNonspace];
        int count = 0;
        foreach (k; firstNonspace .. line.length)
        {
            if (line[k] == c)
                ++count;
            else if (!isSpaceOrTab(line[k]))
                return false;
        }
        return count >= 3;
    }

    /// Try to start a list item at the current position (step 2.6).
    private bool openListItem(ref Node container)
    {
        immutable interrupts = container.kind == NodeKind.paragraph;
        int pos = firstNonspace;
        char c = peek(pos);
        bool ordered;
        char delim;
        int number;
        if (c == '*' || c == '-' || c == '+')
        {
            ++pos;
            if (!isAsciiWs(peek(pos)))
                return false;
            delim = c;
        }
        else if (isAsciiDigit(c))
        {
            int digits = 0;
            do
            {
                number = number * 10 + (peek(pos) - '0');
                ++pos;
                ++digits;
            }
            while (digits < 9 && isAsciiDigit(peek(pos)));
            immutable d = peek(pos);
            if (d != '.' && d != ')')
                return false;
            ++pos;
            if (!isAsciiWs(peek(pos)))
                return false;
            if (interrupts && number != 1)
                return false;
            ordered = true;
            delim = d;
        }
        else
            return false;

        if (interrupts)
        {
            int i = pos;
            while (isSpaceOrTab(peek(i)) && i < line.length)
                ++i;
            if (i >= line.length)
                return false;
        }

        immutable markerWidth = pos - firstNonspace;
        immutable markerOffset = indent;
        advanceOffset(firstNonspace + markerWidth - offset, false);
        immutable savedTab = partiallyConsumedTab;
        immutable savedOffset = offset;
        immutable savedColumn = column;
        while (column - savedColumn <= 5 && offset < line.length && isSpaceOrTab(line[offset]))
            advanceOffset(1, true);
        immutable n = column - savedColumn;
        int padding;
        if (n >= 5 || n < 1 || offset >= line.length)
        {
            padding = markerWidth + 1;
            offset = savedOffset;
            column = savedColumn;
            partiallyConsumedTab = savedTab;
            if (n > 0)
                advanceOffset(1, true);
        }
        else
            padding = markerWidth + n;

        if (container.kind != NodeKind.list || container.ordered != ordered
                || container.delimiter != delim)
        {
            container = addChild(container, NodeKind.list);
            container.ordered = ordered;
            container.delimiter = delim;
            container.start = number;
        }
        container = addChild(container, NodeKind.item);
        container.markerOffset = markerOffset;
        container.padding = padding;
        return true;
    }

    // ------------------------------------------------------------------
    // step 3: add text

    private void addTextToContainer(Node container, Node lastMatched)
    {
        findFirstNonspace();
        if (blank && container.lastChild !is null)
            container.lastChild.lastLineBlank = true;

        immutable ck = container.kind;
        container.lastLineBlank = blank && ck != NodeKind.blockQuote && ck != NodeKind.heading
            && ck != NodeKind.thematicBreak && !(ck == NodeKind.codeBlock && container.fenced)
            && !(ck == NodeKind.item && container.firstChild is null && container.startLine == lineNumber);
        for (Node t = container.parent; t !is null; t = t.parent)
            t.lastLineBlank = false;

        if (current !is lastMatched && container is lastMatched && !blank
                && current.kind == NodeKind.paragraph)
        {
            addLine(current); // lazy continuation
            return;
        }
        while (current !is lastMatched)
            current = finalize(current);

        if (container.kind == NodeKind.codeBlock)
            addLine(container);
        else if (blank)
        {
        }
        else if (container.kind == NodeKind.paragraph || container.kind == NodeKind.heading)
        {
            int end = -1;
            if (container.kind == NodeKind.heading && !container.setext)
                end = chopTrailingHashes();
            advanceOffset(firstNonspace - offset, false);
            addLine(container, end);
        }
        else
        {
            container = addChild(container, NodeKind.paragraph);
            advanceOffset(firstNonspace - offset, false);
            addLine(container);
        }
        current = container;
    }

    /// End index of an ATX heading line after removing the closing `#` sequence.
    private int chopTrailingHashes() const pure nothrow @safe @nogc
    {
        int n = cast(int) line.length;
        while (n > 0 && isAsciiWs(line[n - 1]))
            --n;
        int i = n - 1;
        while (i >= 0 && line[i] == '#')
            --i;
        if (i != n - 1 && i >= 0 && isSpaceOrTab(line[i]))
        {
            n = i;
            while (n > 0 && isAsciiWs(line[n - 1]))
                --n;
        }
        return n;
    }

    // ------------------------------------------------------------------
    // finalisation

    private Node finalize(Node b)
    {
        Node parent = b.parent;
        if (!b.open)
            return parent;
        b.open = false;
        switch (b.kind)
        {
        case NodeKind.codeBlock:
            finalizeCode(b);
            break;
        case NodeKind.list:
            finalizeList(b);
            break;
        default:
            break;
        }
        return parent;
    }

    private static void finalizeCode(Node b)
    {
        if (b.fenced)
        {
            size_t nl = 0;
            while (nl < b.content.length && b.content[nl] != '\n')
                ++nl;
            string rawInfo = b.content[0 .. nl].idup;
            b.info = unescapeBackslashes(trimWs(decodeEntities(rawInfo)));
            b.content = nl < b.content.length ? b.content[nl + 1 .. $] : null;
        }
        else
        {
            // remove trailing blank lines
            auto c = b.content;
            long i = cast(long) c.length - 1;
            while (i >= 0 && isAsciiWs(c[i]))
                --i;
            if (i < 0)
                c = c[0 .. 0];
            else
            {
                size_t k = cast(size_t) i;
                while (k < c.length && c[k] != '\n')
                    ++k;
                c = c[0 .. k];
            }
            b.content = c ~ '\n';
        }
    }

    private static bool endsWithBlankLine(Node node) pure nothrow @safe @nogc
    {
        Node cur = node;
        while (cur !is null)
        {
            if (cur.lastLineChecked)
                return cur.lastLineBlank;
            cur.lastLineChecked = true;
            if ((cur.kind == NodeKind.list || cur.kind == NodeKind.item) && cur.lastChild !is null)
                cur = cur.lastChild;
            else
                return cur.lastLineBlank;
        }
        return false;
    }

    private static void finalizeList(Node list) pure nothrow @safe @nogc
    {
        list.tight = true;
        for (Node item = list.firstChild; item !is null; item = item.next)
        {
            if (item.lastLineBlank && item.next !is null)
            {
                list.tight = false;
                return;
            }
            for (Node sub = item.firstChild; sub !is null; sub = sub.next)
            {
                if ((item.next !is null || sub.next !is null) && endsWithBlankLine(sub))
                {
                    list.tight = false;
                    return;
                }
            }
        }
    }
}
