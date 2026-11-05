/// The Codexa markup language: block tree, inline units and the parser that
/// produces them, reporting the first error in the order the specification
/// prescribes.
module typeset.markup;

import typeset.arith : codepointCount;
import typeset.errors;
import typeset.fonts : Family;
import typeset.settings : Align, parseAlign, parseFamilyWord;
import typeset.values;

// ---------------------------------------------------------------------------
// Inline representation
// ---------------------------------------------------------------------------

/// Kinds of resolved inline units.
enum UnitKind : ubyte
{
    chr, /// an ordinary character (`value` is the code point)
    glue, /// inter-word glue, subject to the sentence rule
    glueOrdinary, /// inter-word glue that is never an extra-space glue
    rigid, /// a rigid space (`~` or `\ `)
    rigidFixed, /// a rigid box of fixed width (`value` millipoints)
    disc, /// a discretionary hyphenation point
    mark, /// a footnote reference mark (`value` is the footnote id)
}

/// One element of the resolved character stream of an inline text.
struct Unit
{
    UnitKind kind; ///
    int style; /// index into `Inline.styles`
    uint value; ///
}

/// Operations a style node applies to its parent's style.
enum StyleOp : ubyte
{
    root,
    bold,
    italic,
    mono,
    up,
    down,
}

/// A node of the style tree; node 0 is the root (the context's initial style).
struct StyleNode
{
    StyleOp op; ///
    int parent; ///
}

/// A block's inline content: styled units plus the tree of styles they refer to.
struct Inline
{
    Unit[] units; ///
    StyleNode[] styles = [StyleNode(StyleOp.root, -1)]; ///

    /// Appends the characters of `text` (spaces become glue) in the root style.
    void appendText(const(char)[] text, int style = 0)
    {
        size_t i;
        while (i < text.length)
        {
            immutable c = decodeAt(text, i);
            if (c == ' ')
            {
                if (units.length == 0 || units[$ - 1].kind != UnitKind.glue)
                    units ~= Unit(UnitKind.glue, style, 0);
            }
            else
                units ~= Unit(UnitKind.chr, style, c);
        }
    }

    /// Removes glue at the very start and the very end.
    void trim()
    {
        size_t a = 0, b = units.length;
        while (a < b && units[a].kind == UnitKind.glue)
            ++a;
        while (b > a && units[b - 1].kind == UnitKind.glue)
            --b;
        units = units[a .. b];
    }
}

/// An inline text made of literal characters (no markup), trimmed.
Inline literalInline(const(char)[] text)
{
    Inline r;
    r.appendText(text);
    r.trim();
    return r;
}

/// The plain text of an inline: spaces for glue and rigid spaces, no
/// discretionary points, runs of spaces collapsed, ends trimmed.
string plainText(const ref Inline inl)
{
    char[] r;
    bool lastSpace = true;
    foreach (u; inl.units)
    {
        final switch (u.kind)
        {
        case UnitKind.chr:
            putUtf8(r, u.value);
            lastSpace = false;
            break;
        case UnitKind.glue:
        case UnitKind.glueOrdinary:
        case UnitKind.rigid:
        case UnitKind.rigidFixed:
            if (!lastSpace)
                r ~= ' ';
            lastSpace = true;
            break;
        case UnitKind.disc:
        case UnitKind.mark:
            break;
        }
    }
    while (r.length && r[$ - 1] == ' ')
        r = r[0 .. $ - 1];
    return r.idup;
}

// ---------------------------------------------------------------------------
// Block tree
// ---------------------------------------------------------------------------

/// Kinds of blocks.
enum BlockKind : ubyte
{
    root,
    doc,
    paragraph,
    heading,
    quote,
    group, /// `@block`
    ulist,
    olist,
    item,
    table,
    pre,
    fig,
    rule,
    vspace,
    newpage,
}

/// One element of a table: a row of cells or a horizontal rule.
struct TableElem
{
    bool isRule; ///
    Inline[] cells; ///
}

/// A node of the block tree. Which fields are meaningful depends on `kind`.
final class Block
{
    BlockKind kind; ///
    Block[] children; /// nested blocks
    Inline text; /// paragraph, heading, item text, figure caption
    int line; /// source line of the block
    int level; /// heading level 1..4
    bool unnumbered; /// heading marked `*`
    // `@block` attributes
    bool hasAlign, hasFont, hasIndent, hasRightIndent, hasSize, hasLeading; ///
    Align alignment; ///
    Family font; ///
    long indent, rightIndent, size, leading; ///
    long start = 1; /// `@ol start`
    int cols; /// `@table cols`
    string colLetters; /// `@table align` letters, one per column
    TableElem[] rows; /// table rows and rules in source order
    string[] preLines; /// `@pre` lines
    long height; /// `@fig` and `@vspace` height
    long width = -1; /// `@fig width`, -1 when absent

    this(BlockKind k, int line)
    {
        kind = k;
        this.line = line;
    }
}

/// Values of a `@doc` block.
struct Meta
{
    string title, author, date; ///
}

/// A footnote's text.
struct Footnote
{
    Inline text; ///
}

/// A parsed document.
final class Document
{
    Meta meta; /// `@doc` values
    bool hasToc; /// whether `@toc` is present
    bool tocTitleSet; /// whether `@toc title=` was given
    string tocTitle; /// literal TOC title from the attribute
    Block[] blocks; /// the top-level blocks (excluding `@doc`/`@toc`)
    Footnote[] footnotes; /// in source order
    int paragraphs, headings, tables, figures; /// block counts
}

// ---------------------------------------------------------------------------
// Inline scanner
// ---------------------------------------------------------------------------

/// Where a stretch of a joined text came from in the source.
struct Segment
{
    size_t offset; /// byte offset in the joined text
    int line; /// source line number
    int col; /// column of the segment's first character
}

private struct OpenTag
{
    size_t pos;
    bool footnote;
    int savedStyle;
    int fnId;
}

private bool isEscapable(char c) pure nothrow @nogc @safe
{
    switch (c)
    {
    case '{', '}', '|', '\\', '@', '~', ' ':
        return true;
    default:
        return false;
    }
}

/// Scans `s` (a block's joined text) into an `Inline`; footnotes found are
/// registered in `doc`. Throws on the first inline error.
Inline scanInline(Document doc, const(char)[] s, const(Segment)[] segs, bool allowFootnote)
{
    enum file = "document.cdx";
    noreturn err(size_t off, ErrorCode code)
    {
        size_t k = 0;
        foreach (i, sg; segs)
            if (sg.offset <= off)
                k = i;
        immutable sg = segs[k];
        immutable col = sg.col + cast(int) codepointCount(s[sg.offset .. off]);
        fail(file, sg.line, col, code);
    }

    Inline[] builders = [Inline.init];
    builders[0].styles = [StyleNode(StyleOp.root, -1)];
    OpenTag[] open;
    int cur = 0;
    int footnoteDepth = 0;

    void push(Unit u)
    {
        builders[$ - 1].units ~= u;
    }

    size_t i;
    while (i < s.length)
    {
        immutable char c = s[i];
        switch (c)
        {
        case '\\':
            if (i + 1 >= s.length)
                err(i, ErrorCode.badEscape);
            immutable char nx = s[i + 1];
            if (nx == ' ')
                push(Unit(UnitKind.rigid, cur, 0));
            else if (nx == '-')
                push(Unit(UnitKind.disc, cur, 0));
            else if (isEscapable(nx))
                push(Unit(UnitKind.chr, cur, nx));
            else
                err(i, ErrorCode.badEscape);
            i += 2;
            break;
        case '~':
            push(Unit(UnitKind.rigid, cur, 0));
            ++i;
            break;
        case '{':
            {
                if (i + 2 >= s.length || s[i + 2] != '|')
                    err(i, ErrorCode.unknownInline);
                immutable char tag = s[i + 1];
                StyleOp op;
                switch (tag)
                {
                case 'b': op = StyleOp.bold; break;
                case 'i': op = StyleOp.italic; break;
                case 'm': op = StyleOp.mono; break;
                case '+': op = StyleOp.up; break;
                case '-': op = StyleOp.down; break;
                case 'n': op = StyleOp.root; break;
                default:
                    err(i, ErrorCode.unknownInline);
                }
                if (tag == 'n')
                {
                    if (footnoteDepth > 0)
                        err(i, ErrorCode.nestedFootnote);
                    if (!allowFootnote)
                        err(i, ErrorCode.footnoteNotAllowed);
                    immutable id = cast(int) doc.footnotes.length;
                    doc.footnotes ~= Footnote.init;
                    push(Unit(UnitKind.mark, cur, id));
                    open ~= OpenTag(i, true, cur, id);
                    Inline fresh;
                    builders ~= fresh;
                    ++footnoteDepth;
                    cur = 0;
                }
                else
                {
                    builders[$ - 1].styles ~= StyleNode(op, cur);
                    open ~= OpenTag(i, false, cur, -1);
                    cur = cast(int) builders[$ - 1].styles.length - 1;
                }
                i += 3;
                break;
            }
        case '}':
            {
                if (open.length == 0)
                    err(i, ErrorCode.strayBrace);
                immutable t = open[$ - 1];
                open = open[0 .. $ - 1];
                if (t.footnote)
                {
                    auto b = builders[$ - 1];
                    builders = builders[0 .. $ - 1];
                    b.trim();
                    doc.footnotes[t.fnId].text = b;
                    --footnoteDepth;
                }
                cur = t.savedStyle;
                ++i;
                break;
            }
        case ' ':
            {
                auto u = builders[$ - 1].units;
                if (u.length == 0 || u[$ - 1].kind != UnitKind.glue)
                    push(Unit(UnitKind.glue, cur, 0));
                ++i;
                break;
            }
        default:
            push(Unit(UnitKind.chr, cur, decodeAt(s, i)));
            break;
        }
    }
    if (open.length)
        err(open[$ - 1].pos, ErrorCode.unclosedInline);
    builders[0].trim();
    return builders[0];
}

// ---------------------------------------------------------------------------
// The document parser
// ---------------------------------------------------------------------------

private enum Dir : ubyte
{
    doc, toc, h1, h2, h3, h4, q, block, ul, ol, li, table, hrule, pre, fig, rule, vspace, newpage, end,
}

private struct DirInfo
{
    Dir dir;
    string[] attrs;
    string[] required;
}

private bool directiveByName(const(char)[] name, out DirInfo info, out bool star)
{
    star = false;
    switch (name)
    {
    case "@doc": info = DirInfo(Dir.doc, [], []); return true;
    case "@toc": info = DirInfo(Dir.toc, ["title"], []); return true;
    case "@q": info = DirInfo(Dir.q, [], []); return true;
    case "@block":
        info = DirInfo(Dir.block, ["align", "indent", "right-indent", "font", "size", "leading"], []);
        return true;
    case "@ul": info = DirInfo(Dir.ul, [], []); return true;
    case "@ol": info = DirInfo(Dir.ol, ["start"], []); return true;
    case "@li": info = DirInfo(Dir.li, [], []); return true;
    case "@table": info = DirInfo(Dir.table, ["cols", "align"], ["cols"]); return true;
    case "@hrule": info = DirInfo(Dir.hrule, [], []); return true;
    case "@pre": info = DirInfo(Dir.pre, [], []); return true;
    case "@fig": info = DirInfo(Dir.fig, ["height", "width"], ["height"]); return true;
    case "@rule": info = DirInfo(Dir.rule, [], []); return true;
    case "@vspace": info = DirInfo(Dir.vspace, ["height"], ["height"]); return true;
    case "@newpage": info = DirInfo(Dir.newpage, [], []); return true;
    case "@end": info = DirInfo(Dir.end, [], []); return true;
    case "@h1", "@h2", "@h3", "@h4":
        info = DirInfo(cast(Dir)(Dir.h1 + (name[2] - '1')), [], []);
        return true;
    case "@h1*", "@h2*", "@h3*", "@h4*":
        info = DirInfo(cast(Dir)(Dir.h1 + (name[2] - '1')), [], []);
        star = true;
        return true;
    default:
        return false;
    }
}

private struct Attr
{
    string name;
    string value;
    int col; /// column of the value's first character (for errors)
}

private struct Pending
{
    Block target; /// paragraph or item the text belongs to (null for none)
    bool isItem;
    Segment[] segs;
    char[] buf;

    bool active() const => target !is null || segs.length > 0;

    void add(const(char)[] text, int line, int col)
    {
        if (segs.length)
            buf ~= ' ';
        segs ~= Segment(buf.length, line, col);
        buf ~= text;
    }

    void clear()
    {
        target = null;
        isItem = false;
        segs = null;
        buf = null;
    }
}

private final class Parser
{
    enum file = "document.cdx";
    const(char)[][] lines;
    Document doc;
    Block root;
    Block[] stack;
    Pending pending;
    Pending figText;
    int topCount;
    bool docSeen;
    int lineNo;
    const(char)[] cur; /// the current line

    this(const(char)[] text)
    {
        lines = splitLines(text);
        doc = new Document;
        root = new Block(BlockKind.root, 0);
    }

    noreturn failAt(size_t byteOff, ErrorCode c)
    {
        fail(file, lineNo, columnAt(cur, byteOff), c);
    }

    Block container()
    {
        return stack.length ? stack[$ - 1] : root;
    }

    void addChild(Block b)
    {
        if (stack.length == 0)
            ++topCount;
        container.children ~= b;
    }

    // ---- pending text --------------------------------------------------

    void flushPending()
    {
        if (!pending.active)
            return;
        auto inl = scanInline(doc, pending.buf, pending.segs, true);
        if (pending.isItem)
            pending.target.text = inl;
        else
        {
            auto b = new Block(BlockKind.paragraph, pending.segs[0].line);
            b.text = inl;
            ++doc.paragraphs;
            addChild(b);
        }
        pending.clear();
    }

    // ---- main loop --------------------------------------------------------

    Document run()
    {
        foreach (idx, line; lines)
        {
            lineNo = cast(int) idx + 1;
            cur = line;
            if (stack.length && stack[$ - 1].kind == BlockKind.pre)
            {
                parsePreLine(line);
                continue;
            }
            size_t ws;
            while (ws < line.length && line[ws] == ' ')
                ++ws;
            if (ws == line.length)
            {
                flushPending();
                continue;
            }
            if (line[ws] == '@')
            {
                flushPending();
                directive(ws);
            }
            else
                textLine(ws);
        }
        lineNo = cast(int) lines.length + 1;
        cur = "";
        flushPending();
        if (stack.length)
            fail(file, lineNo, 1, ErrorCode.missingEnd);
        doc.blocks = root.children;
        return doc;
    }

    void parsePreLine(const(char)[] line)
    {
        size_t a = 0, b = line.length;
        while (a < b && line[a] == ' ')
            ++a;
        while (b > a && line[b - 1] == ' ')
            --b;
        if (line[a .. b] == "@end")
        {
            stack = stack[0 .. $ - 1];
            return;
        }
        stack[$ - 1].preLines ~= line[0 .. (b == a ? 0 : b)].idup;
    }

    // ---- text lines -------------------------------------------------------

    void textLine(size_t ws)
    {
        auto top = container;
        immutable col = columnAt(cur, ws);
        final switch (top.kind)
        {
        case BlockKind.doc:
            metaLine(ws);
            break;
        case BlockKind.table:
            tableRow();
            break;
        case BlockKind.fig:
            figText.add(cur[ws .. $], lineNo, col);
            break;
        case BlockKind.ulist:
        case BlockKind.olist:
            failAt(ws, ErrorCode.textNotAllowed);
        case BlockKind.root:
        case BlockKind.quote:
        case BlockKind.group:
        case BlockKind.item:
            if (!pending.active)
                pending.target = null;
            pending.add(cur[ws .. $], lineNo, col);
            break;
        case BlockKind.paragraph:
        case BlockKind.heading:
        case BlockKind.pre:
        case BlockKind.rule:
        case BlockKind.vspace:
        case BlockKind.newpage:
            assert(0);
        }
    }

    void metaLine(size_t ws)
    {
        auto a = parseAssignment(cur, false);
        if (!a.ok)
            failAt(ws, ErrorCode.badSyntax);
        auto key = a.key(cur);
        string* slot;
        switch (key)
        {
        case "title": slot = &doc.meta.title; break;
        case "author": slot = &doc.meta.author; break;
        case "date": slot = &doc.meta.date; break;
        default:
            failAt(a.keyStart, ErrorCode.unknownMeta);
        }
        if (metaSeen(key))
            failAt(a.keyStart, ErrorCode.duplicateMeta);
        *slot = a.value(cur).idup;
        metaKeys ~= key.idup;
    }

    string[] metaKeys;

    bool metaSeen(const(char)[] k)
    {
        foreach (m; metaKeys)
            if (m == k)
                return true;
        return false;
    }

    void tableRow()
    {
        auto tbl = stack[$ - 1];
        // Split into cells first: a backslash consumes the next character.
        size_t[2][] ranges;
        size_t start = 0, i = 0;
        while (i < cur.length)
        {
            if (cur[i] == '\\')
                i += 2;
            else if (cur[i] == '|')
            {
                ranges ~= [start, i];
                ++i;
                start = i;
            }
            else
                ++i;
        }
        ranges ~= [start, cur.length > start ? cur.length : start];
        if (ranges[$ - 1][1] > cur.length)
            ranges[$ - 1][1] = cur.length;
        if (ranges.length != tbl.cols)
            fail(file, lineNo, 1, ErrorCode.cellCount);
        TableElem e;
        foreach (r; ranges)
        {
            immutable seg = [Segment(0, lineNo, columnAt(cur, r[0]))];
            e.cells ~= scanInline(doc, cur[r[0] .. r[1]], seg, false);
        }
        tbl.rows ~= e;
    }

    // ---- directives -------------------------------------------------------

    void directive(size_t at)
    {
        size_t ne = at;
        while (ne < cur.length && cur[ne] != ' ')
            ++ne;
        DirInfo info;
        bool star;
        if (!directiveByName(cur[at .. ne], info, star))
            failAt(at, ErrorCode.unknownBlock);
        immutable dir = info.dir;
        immutable inlineRest = dir == Dir.li || (dir >= Dir.h1 && dir <= Dir.h4);

        Attr[] attrs;
        if (!inlineRest)
            attrs = parseAttrs(ne, info.attrs);
        foreach (req; info.required)
        {
            bool found;
            foreach (a; attrs)
                if (a.name == req)
                    found = true;
            if (!found)
                failAt(at, ErrorCode.missingAttribute);
        }
        checkPlacement(dir, at);

        // From here on the directive is valid in this position.
        final switch (dir)
        {
        case Dir.doc:
            ++topCount;
            docSeen = true;
            stack ~= new Block(BlockKind.doc, lineNo);
            break;
        case Dir.toc:
            ++topCount;
            doc.hasToc = true;
            foreach (a; attrs)
                if (a.name == "title")
                {
                    doc.tocTitleSet = true;
                    doc.tocTitle = a.value;
                }
            break;
        case Dir.h1:
        case Dir.h2:
        case Dir.h3:
        case Dir.h4:
            {
                size_t ts = ne;
                while (ts < cur.length && cur[ts] == ' ')
                    ++ts;
                immutable seg = [Segment(0, lineNo, columnAt(cur, ts))];
                auto b = new Block(BlockKind.heading, lineNo);
                b.level = dir - Dir.h1 + 1;
                b.unnumbered = star;
                b.text = scanInline(doc, cur[ts .. $], seg, false);
                ++doc.headings;
                addChild(b);
                break;
            }
        case Dir.q:
            pushContainer(new Block(BlockKind.quote, lineNo));
            break;
        case Dir.block:
            {
                auto b = new Block(BlockKind.group, lineNo);
                applyAttrs(dir, attrs, b);
                pushContainer(b);
                break;
            }
        case Dir.ul:
            pushContainer(new Block(BlockKind.ulist, lineNo));
            break;
        case Dir.ol:
            {
                auto b = new Block(BlockKind.olist, lineNo);
                applyAttrs(dir, attrs, b);
                pushContainer(b);
                break;
            }
        case Dir.li:
            {
                if (stack[$ - 1].kind == BlockKind.item)
                    stack = stack[0 .. $ - 1];
                size_t ts = ne;
                while (ts < cur.length && cur[ts] == ' ')
                    ++ts;
                auto b = new Block(BlockKind.item, lineNo);
                stack[$ - 1].children ~= b;
                stack ~= b;
                pending.clear();
                pending.target = b;
                pending.isItem = true;
                pending.add(cur[ts .. $], lineNo, columnAt(cur, ts));
                break;
            }
        case Dir.table:
            {
                auto b = new Block(BlockKind.table, lineNo);
                applyAttrs(dir, attrs, b);
                ++doc.tables;
                pushContainer(b);
                break;
            }
        case Dir.hrule:
            {
                TableElem e;
                e.isRule = true;
                stack[$ - 1].rows ~= e;
                break;
            }
        case Dir.pre:
            pushContainer(new Block(BlockKind.pre, lineNo));
            break;
        case Dir.fig:
            {
                auto b = new Block(BlockKind.fig, lineNo);
                applyAttrs(dir, attrs, b);
                ++doc.figures;
                pushContainer(b);
                figText.clear();
                figText.target = null;
                break;
            }
        case Dir.rule:
            addChild(new Block(BlockKind.rule, lineNo));
            break;
        case Dir.vspace:
            {
                auto b = new Block(BlockKind.vspace, lineNo);
                applyAttrs(dir, attrs, b);
                addChild(b);
                break;
            }
        case Dir.newpage:
            addChild(new Block(BlockKind.newpage, lineNo));
            break;
        case Dir.end:
            endBlock();
            break;
        }
    }

    void pushContainer(Block b)
    {
        addChild(b);
        stack ~= b;
    }

    void endBlock()
    {
        if (stack[$ - 1].kind == BlockKind.item)
            stack = stack[0 .. $ - 1];
        auto b = stack[$ - 1];
        if (b.kind == BlockKind.fig)
        {
            b.text = scanInline(doc, figText.buf, figText.segs.length ? figText.segs : [Segment(0, lineNo, 1)], false);
            figText.clear();
        }
        stack = stack[0 .. $ - 1];
    }

    /// Placement rules (step 3 of the directive checks).
    void checkPlacement(Dir dir, size_t at)
    {
        immutable BlockKind top = stack.length ? stack[$ - 1].kind : BlockKind.root;
        immutable noOrdinary = top == BlockKind.doc || top == BlockKind.table
            || top == BlockKind.fig || top == BlockKind.ulist || top == BlockKind.olist;
        final switch (dir)
        {
        case Dir.end:
            if (stack.length == 0)
                failAt(at, ErrorCode.unexpectedEnd);
            return;
        case Dir.doc:
            if (stack.length != 0 || topCount != 0)
                failAt(at, ErrorCode.blockNotAllowed);
            return;
        case Dir.toc:
            if (noOrdinary)
                failAt(at, ErrorCode.blockNotAllowed);
            if (doc.hasToc)
                failAt(at, ErrorCode.duplicateToc);
            if (stack.length != 0 || !(topCount == 0 || (topCount == 1 && docSeen)))
                failAt(at, ErrorCode.blockNotAllowed);
            return;
        case Dir.li:
            if (top != BlockKind.ulist && top != BlockKind.olist && top != BlockKind.item)
                failAt(at, ErrorCode.blockNotAllowed);
            return;
        case Dir.hrule:
            if (top != BlockKind.table)
                failAt(at, ErrorCode.blockNotAllowed);
            return;
        case Dir.h1:
        case Dir.h2:
        case Dir.h3:
        case Dir.h4:
        case Dir.q:
        case Dir.block:
        case Dir.ul:
        case Dir.ol:
        case Dir.table:
        case Dir.pre:
        case Dir.fig:
        case Dir.rule:
        case Dir.vspace:
        case Dir.newpage:
            if (noOrdinary)
                failAt(at, ErrorCode.blockNotAllowed);
            return;
        }
    }

    // ---- attributes ---------------------------------------------------------

    /// Reads the attribute tokens after the directive name (steps 0-1).
    Attr[] parseAttrs(size_t pos, const(string)[] allowed)
    {
        Attr[] result;
        immutable n = cur.length;
        while (true)
        {
            while (pos < n && cur[pos] == ' ')
                ++pos;
            if (pos >= n)
                break;
            immutable tokStart = pos;
            size_t ne = pos;
            while (ne < n && (isKeyChar(cur[ne]) || (cur[ne] >= 'A' && cur[ne] <= 'Z')))
                ++ne;
            if (ne == pos || ne >= n || cur[ne] != '=')
                failAt(tokStart, ErrorCode.badAttribute);
            immutable name = cur[pos .. ne].idup;
            bool ok;
            foreach (a; allowed)
                if (a == name)
                    ok = true;
            foreach (r; result)
                if (r.name == name)
                    ok = false;
            if (!ok)
                failAt(tokStart, ErrorCode.badAttribute);
            immutable vs = ne + 1;
            if (vs >= n || cur[vs] == ' ')
                failAt(vs, ErrorCode.badAttributeValue);
            size_t after;
            string value;
            if (cur[vs] == '"')
            {
                size_t q = vs + 1;
                while (q < n && cur[q] != '"')
                    ++q;
                if (q >= n)
                    failAt(vs, ErrorCode.badAttributeValue);
                value = cur[vs + 1 .. q].idup;
                after = q + 1;
            }
            else
            {
                size_t q = vs;
                while (q < n && isBareChar(cur[q]))
                    ++q;
                if (q == vs)
                    failAt(vs, ErrorCode.badAttributeValue);
                value = cur[vs .. q].idup;
                after = q;
            }
            if (after < n && cur[after] != ' ')
                failAt(vs, ErrorCode.badAttributeValue);
            result ~= Attr(name, value, columnAt(cur, vs));
            pos = after;
        }
        return result;
    }

    static bool isBareChar(char c) pure nothrow @nogc @safe
    {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
            || c == '.' || c == '+' || c == '-' || c == '%';
    }

    noreturn badValue(const Attr a)
    {
        fail(file, lineNo, a.col, ErrorCode.badAttributeValue);
    }

    long lengthAttr(const Attr a, long lo, long hi)
    {
        long v;
        if (!parseLength(a.value, v) || v < lo || v > hi)
            badValue(a);
        return v;
    }

    long integerAttr(const Attr a, long lo, long hi)
    {
        long v;
        if (!parseInteger(a.value, v) || v < lo || v > hi)
            badValue(a);
        return v;
    }

    /// Value shapes and ranges (step 4), then the cross-attribute check (step 5).
    void applyAttrs(Dir dir, const(Attr)[] attrs, Block b)
    {
        enum maxLen = long.max;
        const(Attr)* alignAttr;
        foreach (ref a; attrs)
        {
            switch (a.name)
            {
            case "align":
                if (dir == Dir.block)
                {
                    if (!parseAlign(a.value, b.alignment))
                        badValue(a);
                    b.hasAlign = true;
                }
                else
                {
                    foreach (ch; a.value)
                        if (ch != 'l' && ch != 'r' && ch != 'c')
                            badValue(a);
                    b.colLetters = a.value;
                    alignAttr = &a;
                }
                break;
            case "indent":
                b.indent = lengthAttr(a, 0, maxLen);
                b.hasIndent = true;
                break;
            case "right-indent":
                b.rightIndent = lengthAttr(a, 0, maxLen);
                b.hasRightIndent = true;
                break;
            case "font":
                if (!parseFamilyWord(a.value, b.font))
                    badValue(a);
                b.hasFont = true;
                break;
            case "size":
                b.size = lengthAttr(a, 1000, 200000);
                b.hasSize = true;
                break;
            case "leading":
                b.leading = lengthAttr(a, 1000, maxLen);
                b.hasLeading = true;
                break;
            case "start":
                b.start = integerAttr(a, 1, 100000);
                break;
            case "cols":
                b.cols = cast(int) integerAttr(a, 1, 20);
                break;
            case "height":
                b.height = lengthAttr(a, 0, maxLen);
                break;
            case "width":
                b.width = lengthAttr(a, 0, maxLen);
                break;
            default:
                break;
            }
        }
        if (dir == Dir.table)
        {
            if (alignAttr is null)
            {
                foreach (_; 0 .. b.cols)
                    b.colLetters ~= 'l';
            }
            else if (b.colLetters.length != b.cols)
                badValue(*alignAttr);
        }
    }
}

/// Parses a `document.cdx` text. Throws `TypesetError` on the first error.
Document parseDocument(const(char)[] text)
{
    return new Parser(text).run();
}
