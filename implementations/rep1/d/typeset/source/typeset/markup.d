/**
 * The Codexa markup language: a line-based block parser and an inline
 * scanner. The result is a $(LREF Document): a tree of $(LREF Block)s whose
 * text is already resolved into $(LREF Token) streams.
 *
 * Errors are reported by throwing `TypesetError` with the position and code
 * required by the specification; only the first error is found.
 */
module typeset.markup;

import std.algorithm : canFind;
import std.conv : to;

import typeset.errors;
import typeset.metrics : Family;
import typeset.settings : Align, parseInteger, parseLength;

/// An element of a resolved inline stream.
struct Token
{
    /// What the token is.
    enum Kind : ubyte
    {
        chr, /// an ordinary character `c`
        space, /// one space (runs collapse into one glue)
        ordinarySpace, /// one space whose glue never uses the sentence rule
        nbsp, /// `~`: a rigid space
        escapedSpace, /// `\ `: a rigid space
        disc, /// `\-`: a discretionary point
        open, /// start of a style tag `c` in `b i m + -`
        close, /// end of the innermost style tag
        note, /// reference to footnote number `note`
        gap, /// rigid box of fixed `width`
    }

    Kind kind;
    dchar c = 0;
    int note;
    long width;

    static Token chr(dchar c) pure nothrow @safe @nogc { return Token(Kind.chr, c); }
    static Token of(Kind k) pure nothrow @safe @nogc { return Token(k); }
}

/// Kinds of block in the tree.
enum BlockKind : ubyte
{
    doc,
    toc,
    heading,
    paragraph,
    quote,
    group, /// `@block`
    ulist,
    olist,
    item, /// `@li`
    table,
    pre,
    figure,
    rule,
    vspace,
    newpage,
}

/// One row of a table: either an `@hrule` or a list of cells.
struct TableRow
{
    bool hrule;
    Token[][] cells;
}

/// A node of the block tree.
final class Block
{
    BlockKind kind;
    Block[] kids; /// children of containers (list items for lists)
    Token[] tokens; /// inline text: paragraph, heading, item text, figure caption
    int level; /// heading level 1..4
    bool unnumbered; /// heading written `@hN*`

    // `@block` overrides
    bool hasAlign, hasFont, hasIndent, hasRightIndent, hasSize, hasLeading;
    Align align_;
    Family font;
    long indent, rightIndent, size, leading;

    long start = 1; /// `@ol start`
    int cols; /// `@table cols`
    dstring aligns; /// `@table` column letters, one per column
    TableRow[] rows; /// `@table` content
    dstring[] preLines; /// `@pre` lines
    long height; /// `@fig` / `@vspace` height
    long width; /// `@fig` width (valid when `hasWidth`)
    bool hasWidth;
    dstring tocTitle; /// `@toc title` (valid when `hasTitle`)
    bool hasTitle;

    this(BlockKind k) pure nothrow @safe @nogc
    {
        kind = k;
    }
}

/// A parsed document.
final class Document
{
    Block[] blocks; /// top-level blocks (excluding `@doc` and `@toc`)
    Block toc; /// the `@toc` block, if any
    dstring title, author, date; /// `@doc` metadata
    Token[][] notes; /// footnote texts; footnote `n` is `notes[n-1]`
    bool hasDoc;
}

private struct Pos
{
    int line, col;
}

private enum file = "document.cdx";

private struct Attr
{
    string name;
    dstring value;
    int nameCol, valCol;
}

private bool isSpace(dchar c) pure nothrow @safe @nogc
{
    return c == ' ';
}

private bool isNameChar(dchar c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-';
}

private bool isBareChar(dchar c) pure nothrow @safe @nogc
{
    return isNameChar(c) || c == '.' || c == '+' || c == '%';
}

/// Parses a document. Throws `TypesetError` on the first error.
Document parseDocument(string source)
{
    auto p = new Parser;
    return p.run(source);
}

private final class Parser
{
    Document doc;
    dstring[] lines;

    Block[] stack; // open containers
    int rootCount; // blocks created at the top level so far
    bool firstIsDoc;
    bool tocSeen;

    // pending paragraph or item text
    bool pendActive;
    Block pendItem; // null for a paragraph
    dchar[] pendText;
    Pos[] pendPos;

    // `@pre` and `@fig` accumulation (the block on top of the stack)
    dchar[] figText;
    Pos[] figPos;
    bool docMetaSeen;
    bool[string] metaSeen;

    Document run(string source)
    {
        doc = new Document;
        // split into lines
        {
            size_t start = 0;
            foreach (i, c; source)
                if (c == '\n')
                {
                    lines ~= source[start .. i].to!dstring;
                    start = i + 1;
                }
            if (start < source.length)
                lines ~= source[start .. $].to!dstring;
        }
        foreach (idx, line; lines)
            processLine(cast(int) idx + 1, line);
        flushPending();
        if (stack.length)
            fail(file, cast(int) lines.length + 1, 1, "missing-end");
        return doc;
    }

    // ---- helpers ---------------------------------------------------------

    Block top() { return stack.length ? stack[$ - 1] : null; }

    void addBlock(Block b)
    {
        if (stack.length)
            stack[$ - 1].kids ~= b;
        else
        {
            if (rootCount == 0 && b.kind == BlockKind.doc)
                firstIsDoc = true;
            ++rootCount;
            if (b.kind != BlockKind.doc && b.kind != BlockKind.toc)
                doc.blocks ~= b;
        }
    }

    void flushPending()
    {
        if (!pendActive)
            return;
        pendActive = false;
        auto tokens = scanInline(pendText, pendPos, true);
        if (pendItem !is null)
            pendItem.tokens = tokens;
        else
        {
            auto b = new Block(BlockKind.paragraph);
            b.tokens = tokens;
            addBlock(b);
        }
        pendItem = null;
        pendText = null;
        pendPos = null;
    }

    // ---- the line loop ---------------------------------------------------

    void processLine(int ln, dstring line)
    {
        // inside @pre everything is raw until the terminator
        if (top !is null && top.kind == BlockKind.pre)
        {
            size_t a = 0, b = line.length;
            while (a < b && line[a] == ' ')
                ++a;
            while (b > a && line[b - 1] == ' ')
                --b;
            if (line[a .. b] == "@end"d)
            {
                stack = stack[0 .. $ - 1];
                return;
            }
            size_t e = line.length;
            while (e > 0 && line[e - 1] == ' ')
                --e;
            top.preLines ~= line[0 .. e];
            return;
        }

        size_t first = 0;
        while (first < line.length && line[first] == ' ')
            ++first;
        if (first == line.length)
        {
            flushPending();
            return;
        }
        if (line[first] == '@')
        {
            flushPending();
            directive(ln, line, first);
            return;
        }
        textLine(ln, line, first);
    }

    void textLine(int ln, dstring line, size_t first)
    {
        auto t = top;
        if (t !is null)
        {
            switch (t.kind)
            {
            case BlockKind.doc:
                metaLine(ln, line, first);
                return;
            case BlockKind.ulist, BlockKind.olist:
                fail(file, ln, cast(int) first + 1, "text-not-allowed");
            case BlockKind.table:
                tableRow(ln, line, t);
                return;
            case BlockKind.figure:
                appendTo(figText, figPos, ln, line, first, figText.length != 0 || figPos.length != 0);
                return;
            default:
                break;
            }
        }
        if (pendActive)
            appendTo(pendText, pendPos, ln, line, first, true);
        else
        {
            pendActive = true;
            pendItem = null;
            pendText = null;
            pendPos = null;
            appendTo(pendText, pendPos, ln, line, first, false);
        }
    }

    static void appendTo(ref dchar[] text, ref Pos[] pos, int ln, dstring line, size_t first, bool join)
    {
        if (join)
        {
            Pos last = pos.length ? pos[$ - 1] : Pos(ln, 1);
            text ~= ' ';
            pos ~= Pos(last.line, last.col + 1);
        }
        foreach (i; first .. line.length)
        {
            text ~= line[i];
            pos ~= Pos(ln, cast(int) i + 1);
        }
    }

    void metaLine(int ln, dstring line, size_t first)
    {
        size_t p = first;
        while (p < line.length && isNameChar(line[p]) && !(line[p] >= 'A' && line[p] <= 'Z'))
            ++p;
        immutable keyEnd = p;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t'))
            ++p;
        if (keyEnd == first || p >= line.length || line[p] != '=')
            fail(file, ln, cast(int) first + 1, "bad-syntax");
        const key = line[first .. keyEnd].to!string;
        if (key != "title" && key != "author" && key != "date")
            fail(file, ln, cast(int) first + 1, "unknown-meta");
        if (key in metaSeen)
            fail(file, ln, cast(int) first + 1, "duplicate-meta");
        metaSeen[key] = true;
        ++p;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t'))
            ++p;
        size_t e = line.length;
        while (e > p && (line[e - 1] == ' ' || line[e - 1] == '\t'))
            --e;
        immutable value = line[p .. e].idup;
        switch (key)
        {
        case "title": doc.title = value; break;
        case "author": doc.author = value; break;
        default: doc.date = value; break;
        }
    }

    void tableRow(int ln, dstring line, Block table)
    {
        // split at unescaped '|'
        size_t[2][] cells;
        size_t start = 0;
        size_t i = 0;
        while (i < line.length)
        {
            if (line[i] == '\\')
                i += 2;
            else if (line[i] == '|')
            {
                cells ~= [start, i];
                start = i + 1;
                ++i;
            }
            else
                ++i;
        }
        cells ~= [start, line.length];
        if (cells.length != cast(size_t) table.cols)
            fail(file, ln, 1, "cell-count");
        TableRow row;
        foreach (c; cells)
        {
            const(dchar)[] text = line[c[0] .. c[1]];
            Pos[] pos;
            foreach (k; c[0] .. c[1])
                pos ~= Pos(ln, cast(int) k + 1);
            row.cells ~= scanInline(text, pos, true);
        }
        table.rows ~= row;
    }

    // ---- directives ------------------------------------------------------

    Attr[] parseAttrs(int ln, dstring line, size_t p, const string[] allowed)
    {
        Attr[] attrs;
        while (true)
        {
            while (p < line.length && line[p] == ' ')
                ++p;
            if (p >= line.length)
                break;
            immutable tokStart = p;
            while (p < line.length && isNameChar(line[p]))
                ++p;
            if (p == tokStart || p >= line.length || line[p] != '=')
                fail(file, ln, cast(int) tokStart + 1, "bad-attribute");
            const name = line[tokStart .. p].to!string;
            if (!allowed.canFind(name))
                fail(file, ln, cast(int) tokStart + 1, "bad-attribute");
            foreach (a; attrs)
                if (a.name == name)
                    fail(file, ln, cast(int) tokStart + 1, "bad-attribute");
            ++p; // '='
            immutable valStart = p;
            dstring value;
            if (p < line.length && line[p] == '"')
            {
                size_t q = p + 1;
                while (q < line.length && line[q] != '"')
                    ++q;
                if (q >= line.length)
                    fail(file, ln, cast(int) valStart + 1, "bad-attribute-value");
                value = line[p + 1 .. q].idup;
                p = q + 1;
            }
            else
            {
                size_t q = p;
                while (q < line.length && isBareChar(line[q]))
                    ++q;
                if (q == p)
                    fail(file, ln, cast(int) valStart + 1, "bad-attribute-value");
                value = line[p .. q].idup;
                p = q;
            }
            if (p < line.length && line[p] != ' ')
                fail(file, ln, cast(int) valStart + 1, "bad-attribute-value");
            attrs ~= Attr(name, value, cast(int) tokStart + 1, cast(int) valStart + 1);
        }
        return attrs;
    }

    static Attr* find(Attr[] attrs, string name)
    {
        foreach (ref a; attrs)
            if (a.name == name)
                return &a;
        return null;
    }

    void directive(int ln, dstring line, size_t at)
    {
        size_t ne = at;
        while (ne < line.length && line[ne] != ' ')
            ++ne;
        const name = line[at .. ne].to!string;
        immutable int atCol = cast(int) at + 1;

        string[] allowed;
        bool takesAttrs = true;
        string[] required;
        switch (name)
        {
        case "@doc", "@q", "@ul", "@pre", "@hrule", "@rule", "@newpage", "@end":
            break;
        case "@toc":
            allowed = ["title"];
            break;
        case "@h1", "@h2", "@h3", "@h4", "@h1*", "@h2*", "@h3*", "@h4*", "@li":
            takesAttrs = false;
            break;
        case "@block":
            allowed = ["align", "indent", "right-indent", "font", "size", "leading"];
            break;
        case "@ol":
            allowed = ["start"];
            break;
        case "@table":
            allowed = ["cols", "align"];
            required = ["cols"];
            break;
        case "@fig":
            allowed = ["height", "width"];
            required = ["height"];
            break;
        case "@vspace":
            allowed = ["height"];
            required = ["height"];
            break;
        default:
            fail(file, ln, atCol, "unknown-block");
        }
        Attr[] attrs;
        if (takesAttrs)
            attrs = parseAttrs(ln, line, ne, allowed);
        foreach (r; required)
            if (find(attrs, r) is null)
                fail(file, ln, atCol, "missing-attribute");

        checkPlacement(ln, atCol, name);

        // value checks (step 4) and cross checks (step 5)
        foreach (ref a; attrs)
            validate(ln, name, a);
        if (name == "@table")
        {
            auto al = find(attrs, "align");
            auto co = find(attrs, "cols");
            long cols;
            parseInteger(co.value, cols);
            if (al !is null && al.value.length != cast(size_t) cols)
                fail(file, ln, al.valCol, "bad-attribute-value");
        }

        act(ln, line, ne, atCol, name, attrs);
    }

    void checkPlacement(int ln, int atCol, string name)
    {
        auto t = top;
        bool bna = false;
        switch (name)
        {
        case "@end":
            if (t is null)
                fail(file, ln, atCol, "unexpected-end");
            return;
        case "@doc":
            if (!(t is null && rootCount == 0))
                bna = true;
            break;
        case "@toc":
            {
                immutable positionOk = t is null && (rootCount == 0 || (rootCount == 1 && firstIsDoc));
                if (tocSeen)
                {
                    immutable noOrdinary = t !is null && (t.kind == BlockKind.doc
                            || t.kind == BlockKind.table || t.kind == BlockKind.figure
                            || ((t.kind == BlockKind.ulist || t.kind == BlockKind.olist)));
                    if (noOrdinary)
                        bna = true;
                    else
                        fail(file, ln, atCol, "duplicate-toc");
                }
                else if (!positionOk)
                    bna = true;
                break;
            }
        case "@li":
            if (!(t !is null && (t.kind == BlockKind.ulist || t.kind == BlockKind.olist || t.kind == BlockKind.item)))
                bna = true;
            break;
        case "@hrule":
            if (!(t !is null && t.kind == BlockKind.table))
                bna = true;
            break;
        default:
            if (t !is null && (t.kind == BlockKind.doc || t.kind == BlockKind.table
                    || t.kind == BlockKind.figure || t.kind == BlockKind.ulist || t.kind == BlockKind.olist))
                bna = true;
            break;
        }
        if (bna)
            fail(file, ln, atCol, "block-not-allowed");
    }

    void validate(int ln, string name, ref Attr a)
    {
        long v;
        bool ok = true;
        switch (a.name)
        {
        case "title":
            break;
        case "align":
            if (name == "@table")
            {
                foreach (c; a.value)
                    if (c != 'l' && c != 'r' && c != 'c')
                        ok = false;
                if (a.value.length == 0)
                    ok = false;
            }
            else
                ok = a.value == "justify"d || a.value == "left"d || a.value == "right"d || a.value == "center"d;
            break;
        case "font":
            ok = a.value == "serif"d || a.value == "sans"d || a.value == "mono"d;
            break;
        case "indent", "right-indent", "width", "height":
            ok = parseLength(a.value, v) && v >= 0;
            break;
        case "size":
            ok = parseLength(a.value, v) && v >= 1000 && v <= 200_000;
            break;
        case "leading":
            ok = parseLength(a.value, v) && v >= 1000;
            break;
        case "start":
            ok = parseInteger(a.value, v) && v >= 1 && v <= 100_000;
            break;
        case "cols":
            ok = parseInteger(a.value, v) && v >= 1 && v <= 20;
            break;
        default:
            break;
        }
        if (!ok)
            fail(file, ln, a.valCol, "bad-attribute-value");
    }

    static long len(Attr* a)
    {
        long v;
        parseLength(a.value, v);
        return v;
    }

    void act(int ln, dstring line, size_t ne, int atCol, string name, Attr[] attrs)
    {
        switch (name)
        {
        case "@end":
            closeInnermost(ln);
            return;
        case "@doc":
            {
                auto b = new Block(BlockKind.doc);
                doc.hasDoc = true;
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@toc":
            {
                auto b = new Block(BlockKind.toc);
                if (auto t = find(attrs, "title"))
                {
                    b.hasTitle = true;
                    b.tocTitle = t.value;
                }
                tocSeen = true;
                doc.toc = b;
                addBlock(b);
                return;
            }
        case "@h1", "@h2", "@h3", "@h4", "@h1*", "@h2*", "@h3*", "@h4*":
            {
                auto b = new Block(BlockKind.heading);
                b.level = name[2] - '0';
                b.unnumbered = name.length == 4;
                size_t p = ne;
                while (p < line.length && line[p] == ' ')
                    ++p;
                dchar[] text;
                Pos[] pos;
                foreach (i; p .. line.length)
                {
                    text ~= line[i];
                    pos ~= Pos(ln, cast(int) i + 1);
                }
                b.tokens = scanInline(text, pos, false);
                addBlock(b);
                return;
            }
        case "@q":
            {
                auto b = new Block(BlockKind.quote);
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@block":
            {
                auto b = new Block(BlockKind.group);
                foreach (ref a; attrs)
                {
                    switch (a.name)
                    {
                    case "align":
                        b.hasAlign = true;
                        b.align_ = a.value == "justify"d ? Align.justify : a.value == "left"d ? Align.left
                            : a.value == "right"d ? Align.right : Align.center;
                        break;
                    case "font":
                        b.hasFont = true;
                        b.font = a.value == "serif"d ? Family.serif : a.value == "sans"d ? Family.sans : Family.mono;
                        break;
                    case "indent":
                        b.hasIndent = true;
                        b.indent = len(&a);
                        break;
                    case "right-indent":
                        b.hasRightIndent = true;
                        b.rightIndent = len(&a);
                        break;
                    case "size":
                        b.hasSize = true;
                        b.size = len(&a);
                        break;
                    default:
                        b.hasLeading = true;
                        b.leading = len(&a);
                        break;
                    }
                }
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@ul", "@ol":
            {
                auto b = new Block(name == "@ul" ? BlockKind.ulist : BlockKind.olist);
                if (auto s = find(attrs, "start"))
                    parseInteger(s.value, b.start);
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@li":
            {
                if (top.kind == BlockKind.item)
                    stack = stack[0 .. $ - 1];
                auto item = new Block(BlockKind.item);
                top.kids ~= item;
                stack ~= item;
                size_t p = ne;
                while (p < line.length && line[p] == ' ')
                    ++p;
                pendActive = true;
                pendItem = item;
                pendText = null;
                pendPos = null;
                foreach (i; p .. line.length)
                {
                    pendText ~= line[i];
                    pendPos ~= Pos(ln, cast(int) i + 1);
                }
                return;
            }
        case "@table":
            {
                auto b = new Block(BlockKind.table);
                long cols;
                parseInteger(find(attrs, "cols").value, cols);
                b.cols = cast(int) cols;
                if (auto al = find(attrs, "align"))
                    b.aligns = al.value;
                else
                {
                    foreach (_; 0 .. b.cols)
                        b.aligns ~= 'l';
                }
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@hrule":
            top.rows ~= TableRow(true, null);
            return;
        case "@pre":
            {
                auto b = new Block(BlockKind.pre);
                addBlock(b);
                stack ~= b;
                return;
            }
        case "@fig":
            {
                auto b = new Block(BlockKind.figure);
                b.height = len(find(attrs, "height"));
                if (auto w = find(attrs, "width"))
                {
                    b.hasWidth = true;
                    b.width = len(w);
                }
                addBlock(b);
                stack ~= b;
                figText = null;
                figPos = null;
                return;
            }
        case "@rule":
            addBlock(new Block(BlockKind.rule));
            return;
        case "@vspace":
            {
                auto b = new Block(BlockKind.vspace);
                b.height = len(find(attrs, "height"));
                addBlock(b);
                return;
            }
        default: // "@newpage"
            addBlock(new Block(BlockKind.newpage));
            return;
        }
    }

    void closeInnermost(int ln)
    {
        if (top.kind == BlockKind.item)
            stack = stack[0 .. $ - 1];
        auto t = top;
        if (t.kind == BlockKind.figure)
            t.tokens = scanInline(figText, figPos, false);
        stack = stack[0 .. $ - 1];
        if (t.kind == BlockKind.figure)
        {
            figText = null;
            figPos = null;
        }
    }

    // ---- inline text -----------------------------------------------------

    private struct Frame
    {
        bool isNote;
        int noteNo;
        Pos pos;
    }

    Token[] scanInline(const(dchar)[] text, const(Pos)[] pos, bool allowNote)
    {
        Token[][] lists = [null];
        Frame[] frames;
        bool inNote = false;
        size_t i = 0;
        immutable n = text.length;
        while (i < n)
        {
            immutable c = text[i];
            if (c == '\\')
            {
                if (i + 1 >= n)
                    fail(file, pos[i].line, pos[i].col, "bad-escape");
                immutable d = text[i + 1];
                switch (d)
                {
                case '{', '}', '|', '\\', '@', '~':
                    lists[$ - 1] ~= Token.chr(d);
                    break;
                case ' ':
                    lists[$ - 1] ~= Token.of(Token.Kind.escapedSpace);
                    break;
                case '-':
                    lists[$ - 1] ~= Token.of(Token.Kind.disc);
                    break;
                default:
                    fail(file, pos[i].line, pos[i].col, "bad-escape");
                }
                i += 2;
            }
            else if (c == '{')
            {
                if (i + 2 >= n || !"bimn+-".canFind(text[i + 1]) || text[i + 2] != '|')
                    fail(file, pos[i].line, pos[i].col, "unknown-inline");
                immutable tag = text[i + 1];
                if (tag == 'n')
                {
                    if (inNote)
                        fail(file, pos[i].line, pos[i].col, "nested-footnote");
                    if (!allowNote)
                        fail(file, pos[i].line, pos[i].col, "footnote-not-allowed");
                    doc.notes ~= null;
                    frames ~= Frame(true, cast(int) doc.notes.length, pos[i]);
                    lists ~= null;
                    inNote = true;
                }
                else
                {
                    frames ~= Frame(false, 0, pos[i]);
                    Token t = Token.of(Token.Kind.open);
                    t.c = tag;
                    lists[$ - 1] ~= t;
                }
                i += 3;
            }
            else if (c == '}')
            {
                if (frames.length == 0)
                    fail(file, pos[i].line, pos[i].col, "stray-brace");
                auto f = frames[$ - 1];
                frames = frames[0 .. $ - 1];
                if (f.isNote)
                {
                    doc.notes[f.noteNo - 1] = lists[$ - 1];
                    lists = lists[0 .. $ - 1];
                    Token t = Token.of(Token.Kind.note);
                    t.note = f.noteNo;
                    lists[$ - 1] ~= t;
                    inNote = false;
                }
                else
                    lists[$ - 1] ~= Token.of(Token.Kind.close);
                ++i;
            }
            else if (c == '~')
            {
                lists[$ - 1] ~= Token.of(Token.Kind.nbsp);
                ++i;
            }
            else if (c == ' ')
            {
                lists[$ - 1] ~= Token.of(Token.Kind.space);
                ++i;
            }
            else
            {
                lists[$ - 1] ~= Token.chr(c);
                ++i;
            }
        }
        if (frames.length)
            fail(file, frames[$ - 1].pos.line, frames[$ - 1].pos.col, "unclosed-inline");
        return lists[0];
    }
}

/// Builds a token stream from literal text (spaces become space tokens).
Token[] literalTokens(const(dchar)[] text) pure nothrow @safe
{
    Token[] r;
    foreach (c; text)
        r ~= c == ' ' ? Token.of(Token.Kind.space) : Token.chr(c);
    return r;
}

unittest
{
    import std.exception : collectException;

    auto d = parseDocument("Hello {b|world}.\n\n@h1 Title\nBody{n|a note}.\n");
    assert(d.blocks.length == 3);
    assert(d.blocks[1].kind == BlockKind.heading && d.blocks[1].level == 1);
    assert(d.notes.length == 1);
    auto e = collectException!TypesetError(parseDocument("@h1 Title\n{z|oops}\n"));
    assert(e.diagnostic.toString == "document.cdx:2:1: unknown-inline");
    e = collectException!TypesetError(parseDocument("@q\nabc\n"));
    assert(e.diagnostic.toString == "document.cdx:3:1: missing-end");
    e = collectException!TypesetError(parseDocument("a {b|c\n"));
    assert(e.diagnostic.toString == "document.cdx:1:3: unclosed-inline");
}
