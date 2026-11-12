/**
 * Block layout: walks the block tree, builds and breaks every horizontal
 * list, and produces the body's vertical list together with the tables,
 * figures, footnote lines and heading records it needs.
 */
module typeset.compose;

import std.algorithm : max, min;
import std.conv : to;

import typeset.hlist;
import typeset.hyphenation : PatternSet;
import typeset.line;
import typeset.linebreak;
import typeset.markup;
import typeset.metrics;
import typeset.settings;
import typeset.units;
import typeset.vlist;

/// Counters reported in `report.txt`.
struct Stats
{
    long lines, paragraphs, headings, tables, figures, footnotes;
    long footnoteSplitLines, hyphenatedLines, overfullLines, emergencyLists, totalDemerits;
}

/// The context a block's text is laid out in.
struct Ctx
{
    Family family;
    bool bold, italic;
    long size, leading, left, measure;
    Align alignment;
    bool hyphenate;
    int depth; /// number of enclosing lists
}

private long clampMeasure(long m) pure nothrow @safe @nogc
{
    return m < 1000 ? 1000 : m;
}

/// Lays out the document's blocks.
final class Composer
{
    const(Settings) s;
    const(FaceSet) faces;
    Document doc;
    PatternSet patterns;

    Line[] lines;
    Row[] rows;
    Figure[] figures;
    Heading[] headings;
    int[][] noteLines;
    Stats stats;
    VBuilder body_;

    private BuildEnv env;
    private BreakParams bp;
    private int[4] counters;

    this(ref const Settings settings, const FaceSet faceSet, PatternSet patternSet, Document document)
    {
        s = settings;
        faces = faceSet;
        patterns = patternSet;
        doc = document;
        env = BuildEnv(faces, &s, patterns);
        bp = BreakParams(s.tolerance, s.linePenalty, s.adjDemerits, s.doubleHyphenDemerits, s.finalHyphenDemerits);
        noteLines = new int[][](doc.notes.length);
        stats.footnotes = doc.notes.length;
    }

    /// Root context from the settings.
    Ctx rootCtx() const
    {
        return Ctx(s.bodyFont, false, false, s.bodySize, s.leading, s.bodyX, s.bodyWidth, s.align_, s.hyphenate, 0);
    }

    /// Walks the whole document, filling `body_`.
    void composeBody()
    {
        walkBlocks(doc.blocks, rootCtx(), body_);
    }

    // ---- horizontal lists ------------------------------------------------

    struct Built
    {
        Item[] items;
        ListMetrics metrics;
    }

    private Built build(const Token[] prefix, const Token[] content, ListStyle style)
    {
        Built b;
        b.items = buildList(prefix, content, style, env);
        foreach (ref it; b.items)
            if (it.note)
                layoutNote(it.note);
        b.metrics = ListMetrics(b.items);
        return b;
    }

    /// Breaks and sets a built list; returns the range of new line indices.
    private int[2] breakAndSet(ref Built b, in LineContext lc)
    {
        auto br = breakLines(b.metrics, lc.measure, lc.firstIndent, bp);
        stats.totalDemerits += br.totalDemerits;
        if (br.emergency)
            ++stats.emergencyLists;
        immutable first = cast(int) lines.length;
        int a = 0;
        foreach (e; br.breaks)
        {
            auto ln = setLine(b.items, b.metrics, a, e, lc, faces);
            ++stats.lines;
            if (ln.overfull)
                ++stats.overfullLines;
            if (ln.hyphenated)
                ++stats.hyphenatedLines;
            lines ~= ln;
            a = e;
        }
        return [first, cast(int) lines.length];
    }

    /// Builds, breaks and sets a list; returns the range of new line indices.
    int[2] makeList(const Token[] prefix, const Token[] content, ListStyle style, in LineContext lc)
    {
        style.justify = lc.alignment == Align.justify;
        auto b = build(prefix, content, style);
        return breakAndSet(b, lc);
    }

    private void layoutNote(int no)
    {
        if (noteLines[no - 1].length)
            return;
        ListStyle st = ListStyle(s.footnoteFont, false, false, s.footnoteSize, true, s.hyphenate);
        LineContext lc;
        lc.left = s.bodyX + s.footnoteIndent;
        lc.measure = s.bodyWidth - s.footnoteIndent;
        lc.alignment = s.align_;
        lc.face = faceIndex(s.footnoteFont, false, false);
        lc.size = s.footnoteSize;
        lc.leading = s.footnoteLeading;
        auto r = makeList(null, doc.notes[no - 1], st, lc);
        int[] idx;
        foreach (i; r[0] .. r[1])
            idx ~= i;
        noteLines[no - 1] = idx;
        // the mark in front of the first line
        immutable face = faceIndex(s.footnoteFont, false, false);
        auto text = no.to!string;
        immutable w = faces[face].width(text.to!dstring, s.footnoteMarkSize);
        lines[r[0]].runs ~= Run(face, s.footnoteMarkSize, s.footnoteMarkRaise,
            s.bodyX + s.footnoteIndent - s.footnoteMarkGap - w, w, text);
    }

    // ---- blocks ----------------------------------------------------------

    private LineContext lineCtx(in Ctx c, long firstIndent, Align a, ubyte face, long size, long leading)
    {
        LineContext lc;
        lc.left = c.left;
        lc.measure = c.measure;
        lc.firstIndent = firstIndent;
        lc.alignment = a;
        lc.face = face;
        lc.size = size;
        lc.leading = leading;
        return lc;
    }

    private void walkBlocks(Block[] blocks, in Ctx ctx, ref VBuilder vb)
    {
        foreach (b; blocks)
            walk(b, ctx, vb);
    }

    private void walk(Block b, in Ctx ctx, ref VBuilder vb)
    {
        final switch (b.kind)
        {
        case BlockKind.doc, BlockKind.toc, BlockKind.item:
            break;
        case BlockKind.paragraph:
            {
                ++stats.paragraphs;
                vb.leaf(s.parSpace, s.parSpace);
                auto st = ListStyle(ctx.family, ctx.bold, ctx.italic, ctx.size, true, ctx.hyphenate);
                auto lc = lineCtx(ctx, s.parIndent, ctx.alignment, faceIndex(ctx.family, ctx.bold, ctx.italic),
                    ctx.size, ctx.leading);
                auto r = makeList(null, b.tokens, st, lc);
                vb.lines(lines, r[0], r[1], false);
                break;
            }
        case BlockKind.heading:
            walkHeading(b, ctx, vb);
            break;
        case BlockKind.quote:
            {
                vb.raise(s.quoteSpace);
                Ctx c = ctx;
                c.left += s.quoteIndent;
                c.measure = clampMeasure(c.measure - 2 * s.quoteIndent);
                walkBlocks(b.kids, c, vb);
                vb.raise(s.quoteSpace);
                break;
            }
        case BlockKind.group:
            {
                Ctx c = ctx;
                if (b.hasAlign)
                    c.alignment = b.align_;
                if (b.hasSize)
                    c.size = b.size;
                if (b.hasLeading)
                    c.leading = b.leading;
                if (b.hasFont)
                    c.family = b.font;
                if (b.hasIndent)
                    c.left += b.indent;
                c.measure = clampMeasure(c.measure - (b.hasIndent ? b.indent : 0)
                        - (b.hasRightIndent ? b.rightIndent : 0));
                walkBlocks(b.kids, c, vb);
                break;
            }
        case BlockKind.ulist, BlockKind.olist:
            walkList(b, ctx, vb);
            break;
        case BlockKind.table:
            walkTable(b, ctx, vb);
            break;
        case BlockKind.pre:
            walkPre(b, ctx, vb);
            break;
        case BlockKind.figure:
            {
                vb.leaf(0, 0);
                VItem v;
                v.kind = VItem.Kind.floatMark;
                v.index = layoutFigure(b);
                vb.items ~= v;
                break;
            }
        case BlockKind.rule:
            {
                vb.leaf(s.ruleSpace, s.ruleSpace);
                VItem v;
                v.kind = VItem.Kind.rule;
                v.x = ctx.left;
                v.w = ctx.measure;
                v.h = s.ruleThickness;
                vb.items ~= v;
                break;
            }
        case BlockKind.vspace:
            vb.pendingAdd += b.height;
            break;
        case BlockKind.newpage:
            vb.forceBreak();
            break;
        }
    }

    private void walkHeading(Block b, in Ctx ctx, ref VBuilder vb)
    {
        ++stats.headings;
        immutable lvl = b.level;
        if (lvl == 1 && s.h1Newpage)
            vb.forceBreak();
        vb.leaf(s.headingSpaceBefore(lvl), s.headingSpaceAfter(lvl));
        Heading h;
        h.level = lvl;
        h.unnumbered = b.unnumbered;
        h.plain = plainText(b.tokens);
        Token[] prefix;
        if (!b.unnumbered && s.headingNumber)
        {
            ++counters[lvl - 1];
            foreach (m; lvl .. 4)
                counters[m] = 0;
            string num = counters[0].to!string;
            foreach (m; 1 .. lvl)
                num ~= "." ~ counters[m].to!string;
            h.number = num;
            prefix = literalTokens(num.to!dstring);
            Token g = Token.of(Token.Kind.gap);
            g.width = s.headingNumberGap;
            prefix ~= g;
        }
        immutable id = cast(int) headings.length;
        headings ~= h;
        auto st = ListStyle(s.headingFont, s.headingBold, s.headingItalic, s.headingSize(lvl), true, ctx.hyphenate);
        auto lc = lineCtx(ctx, 0, s.headingAlign, faceIndex(s.headingFont, s.headingBold, s.headingItalic),
            s.headingSize(lvl), s.headingLeading(lvl));
        auto r = makeList(prefix, b.tokens, st, lc);
        lines[r[0]].headingId = id;
        vb.lines(lines, r[0], r[1], true);
    }

    private void walkList(Block b, in Ctx ctx, ref VBuilder vb)
    {
        vb.raise(s.listSpace);
        Ctx c = ctx;
        c.left += s.listIndent;
        c.measure = clampMeasure(c.measure - s.listIndent);
        c.depth = ctx.depth + 1;
        foreach (idx, item; b.kids)
        {
            if (idx > 0)
                vb.raise(s.listItemSpace);
            vb.leaf(0, 0);
            auto st = ListStyle(c.family, c.bold, c.italic, c.size, true, c.hyphenate);
            auto lc = lineCtx(c, 0, c.alignment, faceIndex(c.family, c.bold, c.italic), c.size, c.leading);
            auto r = makeList(null, item.tokens, st, lc);
            vb.lines(lines, r[0], r[1], false);
            // marker
            string marker;
            immutable number = b.start + cast(long) idx;
            immutable mod = c.depth % 3;
            if (b.kind == BlockKind.ulist)
                marker = mod == 1 ? "•" : mod == 2 ? "–" : "*";
            else
                marker = (mod == 1 ? number.to!string : mod == 2 ? letters(number) : roman(number)) ~ ".";
            immutable face = faceIndex(c.family, false, false);
            immutable w = faces[face].width(marker.to!dstring, c.size);
            lines[r[0]].runs ~= Run(face, c.size, 0, c.left - s.listMarkerGap - w, w, marker);
            walkBlocks(item.kids, c, vb);
        }
        vb.raise(s.listSpace);
    }

    private void walkPre(Block b, in Ctx ctx, ref VBuilder vb)
    {
        vb.leaf(s.preSpace, s.preSpace);
        immutable left = ctx.left + s.preIndent;
        immutable measure = clampMeasure(ctx.measure - s.preIndent);
        immutable face = faceIndex(s.preFont, false, false);
        const f = faces[face];
        immutable first = cast(int) lines.length;
        foreach (text; b.preLines)
        {
            Line ln;
            ln.leading = s.preLeading;
            ln.ascent = scale(f.ascent, s.preSize);
            ln.depth = scale(f.descent, s.preSize);
            ln.startX = left;
            long w = 0;
            if (text.length)
            {
                w = f.width(text, s.preSize);
                ln.runs ~= Run(face, s.preSize, 0, left, w, text.to!string);
            }
            ln.endX = left + w;
            ln.overfull = w > measure;
            ++stats.lines;
            if (ln.overfull)
                ++stats.overfullLines;
            lines ~= ln;
        }
        vb.lines(lines, first, cast(int) lines.length, false);
    }

    // ---- tables ----------------------------------------------------------

    private void walkTable(Block b, in Ctx ctx, ref VBuilder vb)
    {
        ++stats.tables;
        vb.leaf(s.tableSpace, s.tableSpace);
        immutable cols = b.cols;
        immutable face = faceIndex(ctx.family, false, false);

        // measure every cell
        Built[][] cells;
        auto nat = new long[cols];
        auto mn = new long[cols];
        foreach (ref row; b.rows)
        {
            if (row.hrule)
            {
                cells ~= null;
                continue;
            }
            Built[] rowCells;
            foreach (c; 0 .. cols)
            {
                auto st = ListStyle(ctx.family, false, false, ctx.size, false, ctx.hyphenate);
                auto bl = build(null, row.cells[c], st);
                nat[c] = max(nat[c], bl.metrics.naturalWidth());
                int a = 0;
                long widest = 0;
                foreach (e; bl.metrics.breakpoints)
                {
                    widest = max(widest, bl.metrics.line(a, e).width);
                    a = e;
                }
                mn[c] = max(mn[c], widest);
                rowCells ~= bl;
            }
            cells ~= rowCells;
        }

        // column widths
        long sumNat = 0, sumMin = 0;
        foreach (c; 0 .. cols)
        {
            sumNat += nat[c];
            sumMin += mn[c];
        }
        immutable A = max(0, ctx.measure - (cols - 1) * s.tableColGap);
        auto w = new long[cols];
        if (sumNat <= A)
            w[] = nat[];
        else if (sumMin >= A)
            w[] = mn[];
        else
        {
            immutable D = sumNat - A;
            long S = 0;
            foreach (c; 0 .. cols)
                S += nat[c] - mn[c];
            long P = 0, cPrev = 0;
            foreach (c; 0 .. cols)
            {
                P += nat[c] - mn[c];
                immutable ci = fdiv(D * P, S);
                w[c] = nat[c] - (ci - cPrev);
                cPrev = ci;
            }
        }
        long tw = (cols - 1) * s.tableColGap;
        foreach (c; 0 .. cols)
            tw += w[c];
        auto x = new long[cols];
        long acc = ctx.left;
        foreach (c; 0 .. cols)
        {
            x[c] = acc;
            acc += w[c] + s.tableColGap;
        }

        // rows
        bool prevRow = false;
        immutable n = b.rows.length;
        foreach (ri, ref row; b.rows)
        {
            if (row.hrule)
            {
                if (ri > 0)
                    vb.glueItem(s.tableRuleSpace);
                VItem v;
                v.kind = VItem.Kind.rule;
                v.x = ctx.left;
                v.w = tw;
                v.h = s.tableRuleThickness;
                vb.items ~= v;
                if (ri + 1 < n)
                    vb.glueItem(s.tableRuleSpace);
                prevRow = false;
                continue;
            }
            if (prevRow)
                vb.glueItem(s.tableRowSpace);
            int[2][] ranges;
            long aRow = 0, dRow = 0;
            int nRow = 0;
            foreach (c; 0 .. cols)
            {
                Align al = b.aligns[c] == 'l' ? Align.left : b.aligns[c] == 'r' ? Align.right : Align.center;
                LineContext lc;
                lc.left = x[c];
                lc.measure = w[c];
                lc.alignment = al;
                lc.face = face;
                lc.size = ctx.size;
                lc.leading = s.tableLeading;
                auto r = breakAndSet(cells[ri][c], lc);
                ranges ~= r;
                aRow = max(aRow, lines[r[0]].ascent);
                dRow = max(dRow, lines[r[1] - 1].depth);
                nRow = max(nRow, r[1] - r[0]);
            }
            Row rw;
            rw.height = aRow + (nRow - 1) * s.tableLeading + dRow;
            foreach (r; ranges)
                foreach (k; 0 .. r[1] - r[0])
                    rw.cells ~= CellLine(r[0] + k, aRow + k * s.tableLeading);
            VItem v;
            v.kind = VItem.Kind.row;
            v.index = cast(int) rows.length;
            v.h = rw.height;
            rows ~= rw;
            vb.items ~= v;
            prevRow = true;
        }
    }

    // ---- figures ---------------------------------------------------------

    private int layoutFigure(Block b)
    {
        ++stats.figures;
        immutable idx = cast(int) figures.length;
        long W = b.hasWidth ? b.width : s.figureWidth;
        immutable fw = W > 0 ? W : s.bodyWidth;
        immutable fx = s.bodyX + fdiv(s.bodyWidth - fw, 2);
        Figure f;
        f.frame = s.figureFrame;
        f.fx = fx;
        f.fw = fw;
        f.frameHeight = b.height;

        Token[] prefix;
        if (s.figureCaptionPrefix.length)
        {
            prefix = literalTokens(s.figureCaptionPrefix);
            prefix ~= Token.of(Token.Kind.ordinarySpace);
        }
        prefix ~= literalTokens((idx + 1).to!dstring ~ "."d);
        Token g = Token.of(Token.Kind.gap);
        g.width = s.figureCaptionGap;
        prefix ~= g;

        auto st = ListStyle(s.figureCaptionFont, false, false, s.figureCaptionSize, true, s.hyphenate);
        LineContext lc;
        lc.left = fx;
        lc.measure = fw;
        lc.alignment = s.figureCaptionAlign;
        lc.face = faceIndex(s.figureCaptionFont, false, false);
        lc.size = s.figureCaptionSize;
        lc.leading = s.figureCaptionLeading;
        auto r = makeList(prefix, b.tokens, st, lc);
        Placer pl;
        pl.lineSkip = s.lineSkip;
        pl.cursor = b.height + s.figureCaptionSpace;
        foreach (i; r[0] .. r[1])
        {
            immutable bl = pl.line(lines[i].ascent, lines[i].depth, lines[i].leading);
            f.caption ~= CellLine(i, bl);
        }
        f.height = pl.cursor;
        figures ~= f;
        return idx;
    }

    // ---- table of contents ----------------------------------------------

    /// Builds the table of contents' vertical list. `labels[i]` is the page
    /// label of heading `i`.
    VBuilder composeToc(const Block tocBlock, const string[] labels)
    {
        VBuilder vb;
        // title
        {
            vb.leaf(0, s.tocTitleSpaceAfter);
            const title = tocBlock.hasTitle ? tocBlock.tocTitle : s.tocTitle;
            auto st = ListStyle(s.tocTitleFont, s.headingBold, s.headingItalic, s.tocTitleSize, true, s.hyphenate);
            LineContext lc;
            lc.left = s.bodyX;
            lc.measure = s.bodyWidth;
            lc.alignment = s.headingAlign;
            lc.face = faceIndex(s.tocTitleFont, s.headingBold, s.headingItalic);
            lc.size = s.tocTitleSize;
            lc.leading = s.h1Leading;
            auto r = makeList(null, literalTokens(title), st, lc);
            vb.lines(lines, r[0], r[1], false);
        }
        immutable face = faceIndex(s.tocFont, false, false);
        const f = faces[face];
        foreach (i, ref h; headings)
        {
            if (h.unnumbered || h.level > s.tocDepth)
                continue;
            vb.leaf(s.tocEntrySpace, s.tocEntrySpace);
            Token[] prefix;
            if (h.number.length)
            {
                prefix = literalTokens(h.number.to!dstring);
                Token g = Token.of(Token.Kind.gap);
                g.width = s.tocNumberGap;
                prefix ~= g;
            }
            immutable indent = (h.level - 1) * s.tocIndent;
            auto st = ListStyle(s.tocFont, false, false, s.tocSize, false, s.hyphenate);
            LineContext lc;
            lc.left = s.bodyX + indent;
            lc.measure = clampMeasure(s.bodyWidth - indent - s.tocReserve);
            lc.alignment = Align.left;
            lc.face = face;
            lc.size = s.tocSize;
            lc.leading = s.tocLeading;
            auto r = makeList(prefix, literalTokens(h.plain), st, lc);
            vb.lines(lines, r[0], r[1], false);
            // label and leaders on the last line
            auto last = &lines[r[1] - 1];
            immutable label = labels[i];
            immutable lw = f.width(label.to!dstring, s.tocSize);
            immutable labelX = s.bodyX + s.bodyWidth - lw;
            immutable xFrom = last.endX + s.tocLeaderGap;
            immutable xTo = labelX - s.tocLeaderGap;
            immutable unit = f.width(s.tocLeader, s.tocSize);
            immutable k = max(0L, fdiv(xTo - xFrom, unit));
            if (k > 0)
            {
                string txt;
                foreach (_; 0 .. k)
                    txt ~= s.tocLeader.to!string;
                last.runs ~= Run(face, s.tocSize, 0, xTo - k * unit, k * unit, txt);
            }
            last.runs ~= Run(face, s.tocSize, 0, labelX, lw, label);
        }
        return vb;
    }
}
