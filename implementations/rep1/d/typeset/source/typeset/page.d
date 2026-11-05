/// Page breaking: legality of breaks, figure placement, footnote areas,
/// running headers and footers, and the per-page output.
module typeset.page;

import std.algorithm : max, min;
import typeset.arith;
import typeset.fonts;
import typeset.hlist;
import typeset.layout;
import typeset.markup;
import typeset.output;
import typeset.setline;
import typeset.settings;

/// One produced page before header/footer rendering.
struct PageInfo
{
    string label; ///
    long labelNumber; /// numeric value of the label (roman or arabic)
    bool front; ///
    string chapter, section; ///
    OutPage page; ///
}

/// A group of footnote lines awaiting placement.
private struct FnGroup
{
    int fn;
    int start;
    int end;
    bool markless;
}

/// The footnote stack height recurrence of the specification.
private struct FnStack
{
    long cursor;
    bool fresh = true;
    long prevBase, prevDepth;
    int groups;

    void startGroup(long itemSpace)
    {
        if (groups > 0)
            cursor += itemSpace;
        fresh = true;
        ++groups;
    }

    /// Advances over a line and returns its baseline (relative to the stack top).
    long addLine(ref const Line l, long lineSkip)
    {
        immutable long baseline = fresh ? cursor + l.ascent
            : prevBase + max(l.leading, prevDepth + lineSkip + l.ascent);
        cursor = baseline + l.depth;
        prevBase = baseline;
        prevDepth = l.depth;
        fresh = false;
        return baseline;
    }
}

/// Computes, for every position `0 .. items.length`, whether a page break
/// before that item is legal.
bool[] computeLegal(const(VItem)[] items, const(Line)[] lines, const ref Settings s)
{
    immutable n = items.length;
    auto legal = new bool[n + 1];
    legal[] = true;
    legal[0] = false;
    foreach (j; 0 .. n)
    {
        if (items[j].kind != VKind.line)
            continue;
        ref const l = lines[items[j].idx];
        if (l.heading)
        {
            if (l.k != 1)
                legal[j] = false;
        }
        else if (l.k > 1)
        {
            if (!(l.k - 1 >= s.orphans && l.n - l.k + 1 >= s.widows))
                legal[j] = false;
        }
    }
    if (s.keepWithNext)
    {
        size_t j = 0;
        while (j < n)
        {
            if (items[j].kind == VKind.line && lines[items[j].idx].heading)
            {
                immutable g = lines[items[j].idx].group;
                size_t e = j;
                while (e + 1 < n && items[e + 1].kind == VKind.line && lines[items[e + 1].idx].group == g)
                    ++e;
                size_t x = e + 1;
                while (x < n && (items[x].kind == VKind.glue || items[x].kind == VKind.floatMark))
                    ++x;
                foreach (p; e + 1 .. min(x + 1, n))
                    legal[p] = false;
                if (x < n && items[x].kind == VKind.line)
                {
                    immutable cnt = min(s.orphans, lines[items[x].idx].n) - 1;
                    foreach (t; 1 .. cnt + 1)
                        if (x + t < n)
                            legal[x + t] = false;
                }
                j = e + 1;
            }
            else
                ++j;
        }
    }
    legal[n] = n > 0;
    return legal;
}

/// Paginates vertical lists and renders headers and footers.
final class Paginator
{
    Layout L; ///
    const(Settings)* s; ///

    this(Layout layout)
    {
        L = layout;
        s = layout.s;
    }

    private void emitLine(OutPage pg, Region region, ref const Line ln, long baseline)
    {
        foreach (ref r; L.store.runs[ln.runStart .. ln.runStart + ln.runCount])
            pg.text(region, r.face, r.size, r.x, baseline - r.raise, r.width, r.text);
        foreach (ref r; L.store.extras[ln.extraStart .. ln.extraStart + ln.extraCount])
            pg.text(region, r.face, r.size, r.x, baseline - r.raise, r.width, r.text);
    }

    /// Paginates `items`. For the body (`isBody`) figures float and headings are
    /// recorded; otherwise the list is a table of contents.
    PageInfo[] paginate(const(VItem)[] items, bool isBody)
    {
        immutable n = items.length;
        auto legal = computeLegal(items, L.store.lines, *s);
        auto lines = L.store.lines;
        PageInfo[] result;
        size_t i = 0;
        int[] queue;
        size_t qh = 0;
        FnGroup[] carried;
        string chapter, section;
        immutable bodyHeight = s.bodyHeight;
        immutable fnMax = s.footnoteMaxHeight;
        immutable fnFixed = s.footnoteSpaceBefore + s.footnoteRuleThickness + s.footnoteSpaceAfter;

        while (true)
        {
            while (i < n && (items[i].kind == VKind.glue || items[i].kind == VKind.forceBreak))
                ++i;
            if (i == n && qh == queue.length && carried.length == 0)
                break;
            immutable m = cast(int) result.length + 1;
            auto page = new OutPage;
            PageInfo info;
            info.page = page;
            if (isBody)
            {
                info.labelNumber = s.pageStart + m - 1;
                info.label = toDecimal(info.labelNumber);
            }
            else
            {
                info.front = true;
                info.labelNumber = m;
                info.label = toRoman(m);
            }

            // Step 1: figures for the float zone.
            long zone = 0;
            size_t taken = 0;
            immutable bodyLeft = i < n;
            while (qh + taken < queue.length)
            {
                immutable fig = L.figures[queue[qh + taken]];
                immutable nz = zone + fig.height + s.floatSpaceAfter;
                immutable take = bodyLeft ? (bodyHeight - nz >= s.floatMinBody) : (taken == 0 || nz <= bodyHeight);
                if (!take)
                    break;
                zone = nz;
                ++taken;
            }
            {
                long y = s.bodyY;
                foreach (f; 0 .. taken)
                {
                    immutable fig = L.figures[queue[qh + f]];
                    if (fig.frame)
                        page.box(Region.float_, fig.fx, y, fig.fw, fig.frameHeight);
                    foreach (ref ln; lines[fig.lineStart .. fig.lineStart + fig.lineCount])
                        emitLine(page, Region.float_, ln, y + ln.relY);
                    y += fig.height + s.floatSpaceAfter;
                }
                qh += taken;
            }
            immutable bodyTop = s.bodyY + zone;
            immutable goal = bodyHeight - zone;

            // Step 2/3: choose the cut.
            size_t cut = n;
            if (i < n)
            {
                long cursor = 0, prevBase = 0, prevDepth = 0, committed = 0;
                bool fresh = true;
                FnStack st;
                foreach (ref g; carried)
                {
                    st.startGroup(s.footnoteItemSpace);
                    foreach (ref l; lines[g.start .. g.end])
                        st.addLine(l, s.lineSkip);
                }
                long best = -1;
                bool forced = false;
                size_t j = i + 1;
                for (;; ++j)
                {
                    immutable it = items[j - 1];
                    if (it.kind == VKind.forceBreak)
                    {
                        cut = j - 1;
                        forced = true;
                        break;
                    }
                    final switch (it.kind)
                    {
                    case VKind.line:
                        {
                            ref const l = lines[it.idx];
                            immutable baseline = fresh ? cursor + l.ascent
                                : prevBase + max(l.leading, prevDepth + s.lineSkip + l.ascent);
                            cursor = baseline + l.depth;
                            prevBase = baseline;
                            prevDepth = l.depth;
                            fresh = false;
                            committed = cursor;
                            foreach (f; L.store.fnRefs[l.fnStart .. l.fnStart + l.fnCount])
                            {
                                st.startGroup(s.footnoteItemSpace);
                                immutable fl = L.footnotes[f];
                                foreach (ref fln; lines[fl.lineStart .. fl.lineStart + fl.lineCount])
                                    st.addLine(fln, s.lineSkip);
                            }
                            break;
                        }
                    case VKind.glue:
                        cursor += it.a;
                        fresh = true;
                        break;
                    case VKind.rule:
                        cursor += it.c;
                        fresh = true;
                        committed = cursor;
                        break;
                    case VKind.row:
                        cursor += L.rows[it.idx].height;
                        fresh = true;
                        committed = cursor;
                        break;
                    case VKind.floatMark:
                        committed = cursor;
                        break;
                    case VKind.forceBreak:
                        break;
                    }
                    immutable afn = st.groups > 0 ? fnFixed + st.cursor : 0;
                    immutable used = committed + min(afn, fnMax);
                    if (used <= goal && legal[j])
                        best = cast(long) j;
                    if (used > goal || j == n)
                        break;
                }
                if (!forced)
                {
                    if (best >= 0)
                        cut = cast(size_t) best;
                    else
                    {
                        cut = n;
                        foreach (q; i + 1 .. n + 1)
                            if (legal[q])
                            {
                                cut = q;
                                break;
                            }
                    }
                }
            }
            else
                cut = n;

            // Step 4: place the body.
            long B = 0;
            bool bodyEmpty = true;
            {
                long cursor = bodyTop, prevBase = 0, prevDepth = 0, committed = bodyTop;
                bool fresh = true;
                foreach (k; i .. cut)
                {
                    immutable it = items[k];
                    if (it.kind != VKind.glue)
                        bodyEmpty = false;
                    final switch (it.kind)
                    {
                    case VKind.line:
                        {
                            ref const l = lines[it.idx];
                            immutable baseline = fresh ? cursor + l.ascent
                                : prevBase + max(l.leading, prevDepth + s.lineSkip + l.ascent);
                            emitLine(page, Region.body_, l, baseline);
                            cursor = baseline + l.depth;
                            prevBase = baseline;
                            prevDepth = l.depth;
                            fresh = false;
                            committed = cursor;
                            if (isBody && l.headingId >= 0)
                            {
                                auto hd = &L.headings[l.headingId];
                                hd.bodyPage = m;
                                immutable full = hd.number.length ? hd.number ~ " " ~ hd.plain : hd.plain;
                                if (hd.level == 1)
                                    chapter = full;
                                else if (hd.level == 2)
                                    section = full;
                            }
                            break;
                        }
                    case VKind.glue:
                        cursor += it.a;
                        fresh = true;
                        break;
                    case VKind.rule:
                        page.rule(Region.body_, it.a, cursor, it.b, it.c);
                        cursor += it.c;
                        fresh = true;
                        committed = cursor;
                        break;
                    case VKind.row:
                        {
                            immutable row = L.rows[it.idx];
                            foreach (ref l; lines[row.lineStart .. row.lineStart + row.lineCount])
                                emitLine(page, Region.body_, l, cursor + row.aRow + l.aux * s.tableLeading);
                            cursor += row.height;
                            fresh = true;
                            committed = cursor;
                            break;
                        }
                    case VKind.floatMark:
                    case VKind.forceBreak:
                        committed = cursor;
                        break;
                    }
                }
                B = committed - bodyTop;
            }
            // trailing glue only: body counts as empty only if there are no items at all
            {
                size_t last = cut;
                while (last > i && items[last - 1].kind == VKind.glue)
                    --last;
                bodyEmpty = last == i;
            }

            // Step 5: footnotes.
            FnGroup[] cands = carried.dup;
            foreach (k; i .. cut)
                if (items[k].kind == VKind.line)
                {
                    ref const l = lines[items[k].idx];
                    foreach (f; L.store.fnRefs[l.fnStart .. l.fnStart + l.fnCount])
                    {
                        immutable fl = L.footnotes[f];
                        cands ~= FnGroup(f, fl.lineStart, fl.lineStart + fl.lineCount, false);
                    }
                }
            carried = null;
            if (cands.length)
            {
                immutable avail = goal - B - fnFixed;
                auto placed = new int[cands.length];
                {
                    FnStack st;
                    bool stop = false;
                    foreach (gi, ref g; cands)
                    {
                        st.startGroup(s.footnoteItemSpace);
                        foreach (li; g.start .. g.end)
                        {
                            st.addLine(lines[li], s.lineSkip);
                            if (st.cursor > avail)
                            {
                                stop = true;
                                break;
                            }
                            ++placed[gi];
                        }
                        if (stop)
                            break;
                    }
                }
                long total = 0;
                foreach (p; placed)
                    total += p;
                // Minimum split: do not leave too few lines of the partial group.
                foreach (gi, ref g; cands)
                {
                    if (placed[gi] < g.end - g.start)
                    {
                        if (placed[gi] > 0 && placed[gi] < s.footnoteMinSplit && total - placed[gi] > 0)
                        {
                            total -= placed[gi];
                            placed[gi] = 0;
                        }
                        break;
                    }
                }
                if (bodyEmpty && total == 0)
                {
                    placed[0] = 1;
                    total = 1;
                }
                // Carry the rest.
                foreach (gi, ref g; cands)
                {
                    immutable size = g.end - g.start;
                    if (placed[gi] < size)
                    {
                        carried ~= FnGroup(g.fn, g.start + placed[gi], g.end, g.markless || placed[gi] > 0);
                        L.store.stats.splitLines += size - placed[gi];
                    }
                }
                if (total > 0)
                    placeFootnotes(page, cands, placed);
            }

            // Step 6: queue figures.
            if (isBody)
                foreach (k; i .. cut)
                    if (items[k].kind == VKind.floatMark)
                        queue ~= items[k].idx;

            info.chapter = chapter;
            info.section = section;
            result ~= info;
            i = cut;
        }
        return result;
    }

    private void placeFootnotes(OutPage page, const(FnGroup)[] cands, const(int)[] placed)
    {
        FnStack st;
        struct Pl
        {
            long baseline;
            const(Line)* line;
            int fn;
            bool mark;
        }

        Pl[] pls;
        foreach (gi, ref g; cands)
        {
            if (placed[gi] == 0)
                continue;
            st.startGroup(s.footnoteItemSpace);
            foreach (k; 0 .. placed[gi])
            {
                auto ln = &L.store.lines[g.start + k];
                immutable b = st.addLine(*ln, s.lineSkip);
                pls ~= Pl(b, ln, g.fn, k == 0 && !g.markless);
            }
        }
        immutable H = st.cursor;
        immutable ruleTop = s.bodyBottom - H - s.footnoteSpaceAfter - s.footnoteRuleThickness;
        immutable stackTop = ruleTop + s.footnoteRuleThickness + s.footnoteSpaceAfter;
        page.rule(Region.footnote, s.bodyX, ruleTop, s.footnoteRuleWidth, s.footnoteRuleThickness);
        immutable face = faceIndex(s.footnoteFont, false, false);
        foreach (ref p; pls)
        {
            immutable base = stackTop + p.baseline;
            emitLine(page, Region.footnote, *p.line, base);
            if (p.mark)
            {
                immutable txt = toDecimal(p.fn + 1);
                uint[] cps;
                foreach (ch; txt)
                    cps ~= ch;
                immutable w = L.fonts.faces[face].width(cps, s.footnoteMarkSize);
                page.text(Region.footnote, face, s.footnoteMarkSize,
                        s.bodyX + s.footnoteIndent - s.footnoteMarkGap - w,
                        base - s.footnoteMarkRaise, w, txt);
            }
        }
    }

    // ---- running headers and footers ---------------------------------------------------

    private string substitute(const(TextPart)[] tmpl, ref const PageInfo pi, long bodyPages)
    {
        string r;
        foreach (p; tmpl)
        {
            if (!p.isPlaceholder)
            {
                r ~= p.text;
                continue;
            }
            final switch (p.placeholder)
            {
            case Placeholder.page: r ~= pi.label; break;
            case Placeholder.pages: r ~= toDecimal(bodyPages); break;
            case Placeholder.title: r ~= L.doc.meta.title; break;
            case Placeholder.author: r ~= L.doc.meta.author; break;
            case Placeholder.date: r ~= L.doc.meta.date; break;
            case Placeholder.chapter: r ~= pi.chapter; break;
            case Placeholder.section: r ~= pi.section; break;
            }
        }
        return r;
    }

    /// Adds the running header and footer items to a page.
    void renderHeaderFooter(ref PageInfo pi, long bodyPages)
    {
        immutable even = pi.labelNumber % 2 == 0;
        HContext c;
        c.family = s.headerFont;
        c.size = s.headerSize;
        c.leading = s.headerSize;
        c.alignment = Align.left;
        c.hyphenate = false;
        foreach (slot; 0 .. 6)
        {
            immutable text = substitute(s.slot(slot, even), pi, bodyPages);
            if (text.length == 0)
                continue;
            Inline inl;
            inl.appendText(text);
            inl.trim();
            auto h = L.build(inl, c);
            long w = 0;
            foreach (ref it; h.items)
                if (it.kind != ItemKind.penalty)
                    w += it.width;
            bool any;
            foreach (ref it; h.items)
                if (it.kind == ItemKind.box)
                    any = true;
            if (!any)
                continue;
            long x;
            final switch (slot % 3)
            {
            case 0: x = s.bodyX; break;
            case 1: x = s.bodyX + fdiv(s.bodyWidth - w, 2); break;
            case 2: x = s.bodyX + s.bodyWidth - w; break;
            }
            immutable region = slot < 3 ? Region.header : Region.footer;
            immutable y = slot < 3 ? s.headerBaseline : s.footerBaseline;
            foreach (ref it; h.items)
            {
                if (it.kind == ItemKind.box && it.face != noFace)
                    pi.page.text(region, it.face, it.size, x, y, it.width, h.boxText(it));
                if (it.kind != ItemKind.penalty)
                    x += it.width;
            }
        }
    }
}
