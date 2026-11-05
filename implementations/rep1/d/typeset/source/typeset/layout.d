/// Block layout: walks the block tree and produces the flat vertical list,
/// laying out headings, lists, tables, footnotes and figures along the way.
module typeset.layout;

import std.algorithm : max, min;
import typeset.arith;
import typeset.fonts;
import typeset.hlist;
import typeset.hyphen : PatternSet;
import typeset.linebreak;
import typeset.markup;
import typeset.setline;
import typeset.settings;

/// Kinds of vertical items.
enum VKind : ubyte
{
    line,
    glue,
    rule,
    row,
    floatMark,
    forceBreak,
}

/// An item of a vertical list. `line`/`row`/`floatMark` use `idx`; `glue`
/// uses `a` (height); `rule` uses `a` (x), `b` (width), `c` (thickness).
struct VItem
{
    VKind kind; ///
    int idx; ///
    long a, b, c; ///
}

/// A laid-out table row: its cells' lines are `store.lines[lineStart ..
/// lineStart + lineCount]`, each carrying its cell line number in `aux`.
struct Row
{
    int lineStart, lineCount; ///
    long aRow; /// ascent of the row's first baseline
    long height; ///
}

/// A figure block laid out once with baselines relative to its top.
struct Figure
{
    int lineStart, lineCount; ///
    long fx, fw; /// frame x and width
    long frameHeight; ///
    bool frame; ///
    long height; /// total block height
}

/// The lines of one footnote.
struct FootnoteLines
{
    int lineStart, lineCount; ///
    bool done; ///
}

/// A heading as recorded for the table of contents and running headers.
struct HeadingInfo
{
    int level; ///
    bool unnumbered; /// marked `*`
    string number; /// number string, empty when unnumbered
    string plain; /// plain text
    int bodyPage = -1; /// 1-based body page of its first line
}

/// The two registers of the vertical-space rules.
struct Spacer
{
    long pendingMax; ///
    long pendingAdd; ///
    bool started; ///
}

/// Layout state shared by block layout and pagination.
final class Layout
{
    const(Settings)* s; ///
    FontSet fonts; ///
    Document doc; ///
    LineStore store; ///
    VItem[] items; /// the body's vertical list
    Row[] rows; ///
    Figure[] figures; ///
    FootnoteLines[] footnotes; ///
    HeadingInfo[] headings; ///

    private
    {
        HListBuilder builder;
        LineBreaker breaker;
        Spacer sp;
        VItem[]* out_;
        int[4] counters;
    }

    this(const(Settings)* settings, FontSet fonts, PatternSet patterns, Document doc)
    {
        this.s = settings;
        this.fonts = fonts;
        this.doc = doc;
        store = new LineStore;
        builder.env = BuildEnv(fonts, settings, patterns);
        footnotes = new FootnoteLines[doc.footnotes.length];
        out_ = &items;
    }

    // ---- contexts -----------------------------------------------------------

    /// The root context.
    HContext rootContext() const
    {
        HContext c;
        c.family = s.bodyFont;
        c.size = s.bodySize;
        c.leading = s.leading;
        c.left = s.bodyX;
        c.measure = s.bodyWidth;
        c.alignment = s.textAlign;
        c.hyphenate = s.hyphenate;
        return c;
    }

    private static long clampMeasure(long m)
    {
        return m < 1000 ? 1000 : m;
    }

    // ---- spacing ------------------------------------------------------------

    private void emit(VItem it)
    {
        *out_ ~= it;
    }

    private void startLeaf(long before)
    {
        sp.pendingMax = max(sp.pendingMax, before);
        if (sp.started && sp.pendingMax + sp.pendingAdd > 0)
            emit(VItem(VKind.glue, 0, sp.pendingMax + sp.pendingAdd));
    }

    private void endLeaf(long after)
    {
        sp.pendingMax = after;
        sp.pendingAdd = 0;
        sp.started = true;
    }

    // ---- list layout ----------------------------------------------------------

    /// Breaks and sets a horizontal list; returns the first line index.
    int layoutList(const HList h, bool heading, out int count)
    {
        auto r = breaker.breakList(h, *s);
        store.stats.demerits += r.demerits;
        if (r.emergency)
            ++store.stats.emergency;
        count = cast(int) r.breaks.length;
        return setLines(h, r.breaks, fonts, store, heading);
    }

    HList build(const ref Inline inl, in HContext ctx)
    {
        return builder.build(inl, ctx);
    }

    /// Lays out the footnotes referenced by `inl` (once each).
    private void ensureFootnotes(const ref Inline inl)
    {
        foreach (u; inl.units)
            if (u.kind == UnitKind.mark && !footnotes[u.value].done)
            {
                HContext c;
                c.family = s.footnoteFont;
                c.size = s.footnoteSize;
                c.leading = s.footnoteLeading;
                c.left = s.bodyX + s.footnoteIndent;
                c.measure = s.bodyWidth - s.footnoteIndent;
                c.alignment = s.textAlign;
                c.hyphenate = s.hyphenate;
                auto h = build(doc.footnotes[u.value].text, c);
                int cnt;
                immutable first = layoutList(h, false, cnt);
                footnotes[u.value] = FootnoteLines(first, cnt, true);
            }
    }

    private void emitLines(int first, int count)
    {
        foreach (i; 0 .. count)
            emit(VItem(VKind.line, first + i));
    }

    // ---- walking ----------------------------------------------------------------

    /// Lays out the whole document body into `items`.
    void layoutBody()
    {
        walk(doc.blocks, rootContext(), 0);
    }

    private void walk(Block[] blocks, HContext ctx, int listDepth)
    {
        foreach (b; blocks)
            walkBlock(b, ctx, listDepth);
    }

    private void walkBlock(Block b, HContext ctx, int listDepth)
    {
        final switch (b.kind)
        {
        case BlockKind.root:
        case BlockKind.doc:
        case BlockKind.item:
            assert(0);
        case BlockKind.paragraph:
            paragraph(b, ctx);
            break;
        case BlockKind.heading:
            heading(b, ctx);
            break;
        case BlockKind.quote:
            {
                sp.pendingMax = max(sp.pendingMax, s.quoteSpace);
                auto c = ctx;
                c.left += s.quoteIndent;
                c.measure = clampMeasure(c.measure - 2 * s.quoteIndent);
                walk(b.children, c, listDepth);
                sp.pendingMax = max(sp.pendingMax, s.quoteSpace);
                break;
            }
        case BlockKind.group:
            {
                auto c = ctx;
                if (b.hasAlign)
                    c.alignment = b.alignment;
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
                walk(b.children, c, listDepth);
                break;
            }
        case BlockKind.ulist:
        case BlockKind.olist:
            list(b, ctx, listDepth + 1);
            break;
        case BlockKind.table:
            table(b, ctx);
            break;
        case BlockKind.pre:
            pre(b, ctx);
            break;
        case BlockKind.fig:
            startLeaf(0);
            emit(VItem(VKind.floatMark, layoutFigure(b)));
            endLeaf(0);
            break;
        case BlockKind.rule:
            startLeaf(s.ruleSpace);
            emit(VItem(VKind.rule, 0, ctx.left, ctx.measure, s.ruleThickness));
            endLeaf(s.ruleSpace);
            break;
        case BlockKind.vspace:
            sp.pendingAdd += b.height;
            break;
        case BlockKind.newpage:
            emit(VItem(VKind.forceBreak));
            sp.pendingMax = 0;
            sp.pendingAdd = 0;
            break;
        }
    }

    private void paragraph(Block b, HContext ctx)
    {
        startLeaf(s.parSpace);
        ensureFootnotes(b.text);
        ctx.firstIndent = s.parIndent;
        ctx.bold = false;
        ctx.italic = false;
        auto h = build(b.text, ctx);
        int cnt;
        immutable first = layoutList(h, false, cnt);
        emitLines(first, cnt);
        endLeaf(s.parSpace);
    }

    private void heading(Block b, HContext ctx)
    {
        immutable lvl = b.level;
        if (lvl == 1 && s.h1Newpage)
        {
            emit(VItem(VKind.forceBreak));
            sp.pendingMax = 0;
            sp.pendingAdd = 0;
        }
        startLeaf(s.hSpaceBefore[lvl - 1]);
        HeadingInfo info;
        info.level = lvl;
        info.unnumbered = b.unnumbered;
        info.plain = plainText(b.text);
        Inline inl;
        inl.styles = b.text.styles;
        if (!b.unnumbered && s.headingNumber)
        {
            ++counters[lvl - 1];
            foreach (m; lvl .. 4)
                counters[m] = 0;
            string num = toDecimal(counters[0]);
            foreach (m; 1 .. lvl)
                num ~= "." ~ toDecimal(counters[m]);
            info.number = num;
            inl.appendText(num);
            inl.units ~= Unit(UnitKind.rigidFixed, 0, cast(uint) s.headingNumberGap);
        }
        inl.units ~= b.text.units;
        HContext c = ctx;
        c.family = s.headingFont;
        c.bold = s.headingBold;
        c.italic = s.headingItalic;
        c.size = s.hSize[lvl - 1];
        c.leading = s.hLeading[lvl - 1];
        c.alignment = s.headingAlign;
        c.firstIndent = 0;
        auto h = build(inl, c);
        int cnt;
        immutable first = layoutList(h, true, cnt);
        store.lines[first].headingId = cast(int) headings.length;
        headings ~= info;
        emitLines(first, cnt);
        endLeaf(s.hSpaceAfter[lvl - 1]);
    }

    // ---- lists ---------------------------------------------------------------------

    private string markerText(bool ordered, int depth, long number)
    {
        immutable m = depth % 3;
        if (!ordered)
            return m == 1 ? "•" : (m == 2 ? "–" : "*");
        final switch (m)
        {
        case 1: return toDecimal(number) ~ ".";
        case 2: return toLetters(number) ~ ".";
        case 0: return toRoman(number) ~ ".";
        }
    }

    private void list(Block b, HContext ctx, int depth)
    {
        immutable ordered = b.kind == BlockKind.olist;
        sp.pendingMax = max(sp.pendingMax, s.listSpace);
        auto lc = ctx;
        lc.left += s.listIndent;
        lc.measure = clampMeasure(lc.measure - s.listIndent);
        foreach (idx, item; b.children)
        {
            if (idx > 0)
                sp.pendingMax = max(sp.pendingMax, s.listItemSpace);
            startLeaf(0);
            ensureFootnotes(item.text);
            auto ic = lc;
            ic.firstIndent = 0;
            ic.bold = false;
            ic.italic = false;
            auto h = build(item.text, ic);
            int cnt;
            immutable first = layoutList(h, false, cnt);
            // The marker rides on the item's first line.
            immutable txt = markerText(ordered, depth, b.start + cast(long) idx);
            immutable face = faceIndex(lc.family, false, false);
            uint[] cps;
            foreach (dchar ch; txt)
                cps ~= ch;
            immutable mw = fonts.faces[face].width(cps, lc.size);
            auto line = &store.lines[first];
            line.extraStart = cast(int) store.extras.length;
            line.extraCount = 1;
            store.extras ~= Run(lc.left - s.listMarkerGap - mw, cast(int) mw, cast(int) lc.size, 0, face, txt);
            emitLines(first, cnt);
            endLeaf(0);
            walk(item.children, lc, depth);
        }
        sp.pendingMax = max(sp.pendingMax, s.listSpace);
    }

    // ---- preformatted text ------------------------------------------------------------

    private void pre(Block b, HContext ctx)
    {
        startLeaf(s.preSpace);
        HContext c = ctx;
        c.family = s.preFont;
        c.bold = false;
        c.italic = false;
        c.size = s.preSize;
        c.leading = s.preLeading;
        c.left += s.preIndent;
        c.measure = clampMeasure(c.measure - s.preIndent);
        c.alignment = Align.left;
        c.firstIndent = 0;
        immutable face = faceIndex(c.family, false, false);
        immutable group = store.nextGroup++;
        immutable first = cast(int) store.lines.length;
        foreach (ln; b.preLines)
        {
            auto h = new HList;
            h.ctx = c;
            if (ln.length)
            {
                uint[] cps;
                foreach (dchar ch; ln)
                    cps ~= ch;
                Item box;
                box.kind = ItemKind.box;
                box.face = face;
                box.size = cast(int) c.size;
                box.textLen = cast(int) ln.length;
                h.text = ln.dup;
                box.width = cast(int) fonts.faces[face].width(cps, c.size);
                box.frag = 0;
                h.items ~= box;
            }
            Item p1;
            p1.kind = ItemKind.penalty;
            p1.a = 10000;
            h.items ~= p1;
            Item gl;
            gl.kind = ItemKind.glue;
            gl.flag = true;
            h.items ~= gl;
            Item p2;
            p2.kind = ItemKind.penalty;
            p2.a = -10000;
            h.items ~= p2;
            h.finish();
            setLines(h, [h.finalBreak], fonts, store, false);
        }
        immutable cnt = cast(int) b.preLines.length;
        foreach (i; 0 .. cnt)
        {
            auto l = &store.lines[first + i];
            l.group = group;
            l.k = i + 1;
            l.n = cnt;
        }
        emitLines(first, cnt);
        endLeaf(s.preSpace);
    }

    // ---- tables ---------------------------------------------------------------------------

    private void table(Block b, HContext ctx)
    {
        startLeaf(s.tableSpace);
        immutable cols = b.cols;
        HList[][] lists = new HList[][b.rows.length];
        auto nat = new long[cols];
        auto mn = new long[cols];
        foreach (ri, ref e; b.rows)
        {
            if (e.isRule)
                continue;
            lists[ri] = new HList[cols];
            foreach (ci, ref cell; e.cells)
            {
                HContext c;
                c.family = ctx.family;
                c.size = ctx.size;
                c.leading = s.tableLeading;
                c.alignment = b.colLetters[ci] == 'l' ? Align.left : (b.colLetters[ci] == 'r' ? Align.right : Align.center);
                c.hyphenate = ctx.hyphenate;
                auto h = build(cell, c);
                lists[ri][ci] = h;
                nat[ci] = max(nat[ci], h.naturalWidth);
                long m = 0;
                int prev = -1;
                foreach (bp; h.breakpoints)
                {
                    m = max(m, h.lineWidth(prev, bp));
                    prev = bp;
                }
                mn[ci] = max(mn[ci], m);
            }
        }
        // Column widths.
        immutable A = max(0L, ctx.measure - (cols - 1) * s.tableColGap);
        long sumNat = 0, sumMin = 0;
        foreach (i; 0 .. cols)
        {
            sumNat += nat[i];
            sumMin += mn[i];
        }
        auto w = new long[cols];
        if (sumNat <= A)
            w[] = nat[];
        else if (sumMin >= A)
            w[] = mn[];
        else
        {
            immutable D = sumNat - A;
            long S = 0;
            foreach (i; 0 .. cols)
                S += nat[i] - mn[i];
            long P = 0, Cprev = 0;
            foreach (i; 0 .. cols)
            {
                P += nat[i] - mn[i];
                immutable C = fdiv(D * P, S);
                w[i] = nat[i] - (C - Cprev);
                Cprev = C;
            }
        }
        long TW = (cols - 1) * s.tableColGap;
        auto xs = new long[cols];
        long x = ctx.left;
        foreach (i; 0 .. cols)
        {
            TW += w[i];
            xs[i] = x;
            x += w[i] + s.tableColGap;
        }

        bool prevRow = false;
        foreach (ri, ref e; b.rows)
        {
            if (e.isRule)
            {
                if (ri != 0)
                    emit(VItem(VKind.glue, 0, s.tableRuleSpace));
                emit(VItem(VKind.rule, 0, ctx.left, TW, s.tableRuleThickness));
                if (ri + 1 != b.rows.length)
                    emit(VItem(VKind.glue, 0, s.tableRuleSpace));
                prevRow = false;
                continue;
            }
            if (prevRow)
                emit(VItem(VKind.glue, 0, s.tableRowSpace));
            prevRow = true;
            Row row;
            row.lineStart = cast(int) store.lines.length;
            long aRow = 0, dRow = 0;
            int nRow = 0;
            foreach (ci; 0 .. cols)
            {
                auto h = lists[ri][ci];
                h.ctx.left = xs[ci];
                h.ctx.measure = w[ci];
                int cnt;
                immutable first = layoutList(h, false, cnt);
                foreach (k; 0 .. cnt)
                    store.lines[first + k].aux = k;
                aRow = max(aRow, store.lines[first].ascent);
                dRow = max(dRow, store.lines[first + cnt - 1].depth);
                nRow = max(nRow, cnt);
            }
            row.lineCount = cast(int) store.lines.length - row.lineStart;
            row.aRow = aRow;
            row.height = aRow + (nRow - 1) * s.tableLeading + dRow;
            rows ~= row;
            emit(VItem(VKind.row, cast(int) rows.length - 1));
        }
        endLeaf(s.tableSpace);
    }

    // ---- figures --------------------------------------------------------------------------------

    private int layoutFigure(Block f)
    {
        immutable W = f.width >= 0 ? f.width : s.figureWidth;
        immutable fw = W > 0 ? W : s.bodyWidth;
        immutable fx = s.bodyX + fdiv(s.bodyWidth - fw, 2);
        Figure fig;
        fig.fx = fx;
        fig.fw = fw;
        fig.frameHeight = f.height;
        fig.frame = s.figureFrame;
        immutable number = cast(int) figures.length + 1;

        Inline cap;
        cap.styles = f.text.styles;
        immutable prefix = literalText(s.figureCaptionPrefix);
        if (prefix.length)
        {
            cap.appendText(prefix);
            cap.trim();
            cap.units ~= Unit(UnitKind.glueOrdinary, 0, 0);
        }
        cap.appendText(toDecimal(number) ~ ".");
        cap.units ~= Unit(UnitKind.rigidFixed, 0, cast(uint) s.figureCaptionGap);
        cap.units ~= f.text.units;

        HContext c;
        c.family = s.figureCaptionFont;
        c.size = s.figureCaptionSize;
        c.leading = s.figureCaptionLeading;
        c.left = fx;
        c.measure = fw;
        c.alignment = s.figureCaptionAlign;
        c.hyphenate = s.hyphenate;
        auto h = build(cap, c);
        int cnt;
        immutable first = layoutList(h, false, cnt);
        long prevBase = 0, prevDepth = 0;
        foreach (k; 0 .. cnt)
        {
            auto l = &store.lines[first + k];
            if (k == 0)
                l.relY = f.height + s.figureCaptionSpace + l.ascent;
            else
                l.relY = prevBase + max(l.leading, prevDepth + s.lineSkip + l.ascent);
            prevBase = l.relY;
            prevDepth = l.depth;
        }
        fig.lineStart = first;
        fig.lineCount = cnt;
        fig.height = prevBase + prevDepth;
        figures ~= fig;
        return cast(int) figures.length - 1;
    }

    // ---- the table of contents ------------------------------------------------------------------

    /// Builds the vertical list of the table of contents. `labelOf` gives the
    /// label of a body page number.
    VItem[] layoutToc(string delegate(int bodyPage) labelOf)
    {
        VItem[] result;
        auto savedOut = out_;
        auto savedSp = sp;
        out_ = &result;
        sp = Spacer.init;

        HContext tc;
        tc.family = s.tocTitleFont;
        tc.bold = s.headingBold;
        tc.italic = s.headingItalic;
        tc.size = s.tocTitleSize;
        tc.leading = s.hLeading[0];
        tc.left = s.bodyX;
        tc.measure = s.bodyWidth;
        tc.alignment = s.headingAlign;
        tc.hyphenate = s.hyphenate;
        startLeaf(0);
        {
            auto inl = literalInline(doc.tocTitleSet ? doc.tocTitle : literalText(s.tocTitle));
            auto h = build(inl, tc);
            int cnt;
            immutable first = layoutList(h, false, cnt);
            emitLines(first, cnt);
        }
        endLeaf(s.tocTitleSpaceAfter);

        immutable tface = faceIndex(s.tocFont, false, false);
        foreach (ref hd; headings)
        {
            if (hd.unnumbered || hd.level > s.tocDepth)
                continue;
            startLeaf(s.tocEntrySpace);
            HContext c;
            c.family = s.tocFont;
            c.size = s.tocSize;
            c.leading = s.tocLeading;
            c.left = s.bodyX + (hd.level - 1) * s.tocIndent;
            c.measure = clampMeasure(s.bodyWidth - (hd.level - 1) * s.tocIndent - s.tocReserve);
            c.alignment = Align.left;
            c.hyphenate = s.hyphenate;
            Inline inl;
            if (hd.number.length)
            {
                inl.appendText(hd.number);
                inl.units ~= Unit(UnitKind.rigidFixed, 0, cast(uint) s.tocNumberGap);
            }
            inl.appendText(hd.plain);
            auto h = build(inl, c);
            int cnt;
            immutable first = layoutList(h, false, cnt);
            emitLines(first, cnt);

            // Leaders and the page label on the last line.
            auto last = &store.lines[first + cnt - 1];
            immutable label = labelOf(hd.bodyPage);
            uint[] lcps;
            foreach (dchar ch; label)
                lcps ~= ch;
            immutable lw = fonts.faces[tface].width(lcps, s.tocSize);
            immutable labelX = s.bodyX + s.bodyWidth - lw;
            immutable xFrom = last.endX + s.tocLeaderGap;
            immutable xTo = labelX - s.tocLeaderGap;
            immutable leader = literalText(s.tocLeader);
            uint[] ucps;
            foreach (dchar ch; leader)
                ucps ~= ch;
            immutable unit = fonts.faces[tface].width(ucps, s.tocSize);
            immutable k = max(0L, fdiv(xTo - xFrom, unit));
            last.extraStart = cast(int) store.extras.length;
            last.extraCount = 0;
            if (k > 0)
            {
                string rep;
                foreach (_; 0 .. k)
                    rep ~= leader;
                store.extras ~= Run(xTo - k * unit, cast(int)(k * unit), cast(int) s.tocSize, 0, tface, rep);
                ++last.extraCount;
            }
            store.extras ~= Run(labelX, cast(int) lw, cast(int) s.tocSize, 0, tface, label);
            ++last.extraCount;
            endLeaf(s.tocEntrySpace);
        }
        out_ = savedOut;
        sp = savedSp;
        return result;
    }
}
