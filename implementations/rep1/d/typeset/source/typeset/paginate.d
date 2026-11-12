/**
 * Page breaking: the per-page forward scan with break legality (widows,
 * orphans, keep-with-next, forced breaks), footnote reservation and
 * splitting, and the placement of floating figures.
 */
module typeset.paginate;

import std.algorithm : min;
import std.conv : to;

import typeset.layout;
import typeset.line;
import typeset.metrics : faceNames;
import typeset.settings;
import typeset.vlist;

/// A footnote (or the unplaced tail of one) waiting for page space.
struct FnGroup
{
    int note; /// footnote number (1-based)
    int from; /// index of the first line still to place (0: whole footnote)
}

/// One paginated page before headers and footers are added.
struct PageResult
{
    PlacedItem[] items;
    int[] headingStarts; /// headings whose first line is on this page
}

/// What the paginator reads.
struct PageSource
{
    const(VItem)[] items;
    const(Line)[] lines;
    const(Row)[] rows;
    const(Figure)[] figures;
    const(int[])[] noteLines;
}

private PlacedItem textItem(Region region, in Run r, long baseline)
{
    PlacedItem p;
    p.region = region;
    p.kind = ItemKind.text;
    p.face = faceNames[r.face];
    p.size = r.size;
    p.x = r.x;
    p.y = baseline - r.raise;
    p.width = r.width;
    p.text = r.text;
    return p;
}

/// Paginates `src`; `footnoteSplitLines` receives the number of footnote
/// lines carried across pages.
PageResult[] paginate(in PageSource src, ref const Settings s, ref long footnoteSplitLines)
{
    immutable n = src.items.length;
    const items = src.items;
    auto legal = computeLegal(items, s);

    PageResult[] pages;
    size_t i = 0;
    int[] queue;
    size_t qhead = 0;
    FnGroup[] carried;

    while (true)
    {
        while (i < n && (items[i].kind == VItem.Kind.glue || items[i].kind == VItem.Kind.forceBreak))
            ++i;
        if (i == n && qhead >= queue.length && carried.length == 0)
            break;

        PageResult page;

        // step 1: figures
        long zone = 0;
        size_t figStart = qhead;
        long figTop = s.bodyY;
        while (qhead < queue.length)
        {
            const fig = src.figures[queue[qhead]];
            immutable z1 = zone + fig.height + s.floatSpaceAfter;
            bool take;
            if (i < n)
                take = s.bodyHeight - z1 >= s.floatMinBody;
            else
                take = qhead == figStart || z1 <= s.bodyHeight;
            if (!take)
                break;
            // place the figure
            if (fig.frame)
            {
                PlacedItem b;
                b.region = Region.float_;
                b.kind = ItemKind.box;
                b.x = fig.fx;
                b.y = figTop;
                b.width = fig.fw;
                b.height = fig.frameHeight;
                page.items ~= b;
            }
            foreach (cl; fig.caption)
                foreach (ref r; src.lines[cl.line].runs)
                    page.items ~= textItem(Region.float_, r, figTop + cl.offset);
            figTop += fig.height + s.floatSpaceAfter;
            zone = z1;
            ++qhead;
        }
        immutable bodyTop = s.bodyY + zone;
        immutable goal = s.bodyHeight - zone;

        // step 2/3: choose the cut
        size_t cut;
        if (i < n)
            cut = chooseCut(src, s, legal, i, bodyTop, goal, carried);
        else
            cut = n;

        // step 4: place the body
        long used = 0;
        {
            Placer pl;
            pl.cursor = bodyTop;
            pl.lineSkip = s.lineSkip;
            long lastNonGlue = bodyTop;
            foreach (j; i .. cut)
            {
                const it = items[j];
                final switch (it.kind)
                {
                case VItem.Kind.line:
                    {
                        const ln = src.lines[it.index];
                        immutable bl = pl.line(ln.ascent, ln.depth, ln.leading);
                        foreach (ref r; ln.runs)
                            page.items ~= textItem(Region.body_, r, bl);
                        if (ln.headingId >= 0)
                            page.headingStarts ~= ln.headingId;
                        lastNonGlue = pl.cursor;
                        break;
                    }
                case VItem.Kind.glue:
                    pl.glue(it.h);
                    break;
                case VItem.Kind.rule:
                    {
                        immutable top = pl.block(it.h);
                        PlacedItem p;
                        p.region = Region.body_;
                        p.kind = ItemKind.rule;
                        p.x = it.x;
                        p.y = top;
                        p.width = it.w;
                        p.height = it.h;
                        page.items ~= p;
                        lastNonGlue = pl.cursor;
                        break;
                    }
                case VItem.Kind.row:
                    {
                        immutable top = pl.block(it.h);
                        foreach (cl; src.rows[it.index].cells)
                            foreach (ref r; src.lines[cl.line].runs)
                                page.items ~= textItem(Region.body_, r, top + cl.offset);
                        lastNonGlue = pl.cursor;
                        break;
                    }
                case VItem.Kind.floatMark:
                    lastNonGlue = pl.cursor;
                    break;
                case VItem.Kind.forceBreak:
                    break;
                }
            }
            used = lastNonGlue - bodyTop;
        }

        // step 5: footnotes
        FnGroup[] candidates = carried.dup;
        foreach (j; i .. cut)
            if (items[j].kind == VItem.Kind.line)
                foreach (no; src.lines[items[j].index].notes)
                    candidates ~= FnGroup(no, 0);
        if (candidates.length)
        {
            immutable avail = goal - used - s.footnoteSpaceBefore - s.footnoteRuleThickness - s.footnoteSpaceAfter;
            // heights of every prefix
            struct LineRef
            {
                int group;
                int line;
                long height; // stack height including this line
            }

            LineRef[] flat;
            long[] groupStart; // index into flat of each group's first line
            Placer pl;
            pl.lineSkip = s.lineSkip;
            foreach (gi, g; candidates)
            {
                if (gi > 0)
                {
                    pl.cursor += s.footnoteItemSpace;
                    pl.fresh = true;
                }
                groupStart ~= flat.length;
                foreach (li; src.noteLines[g.note - 1][g.from .. $])
                {
                    const ln = src.lines[li];
                    pl.line(ln.ascent, ln.depth, ln.leading);
                    flat ~= LineRef(cast(int) gi, li, pl.cursor);
                }
            }
            size_t count = 0;
            while (count < flat.length && flat[count].height <= avail)
                ++count;
            if (count > 0 && count < flat.length && flat[count - 1].group == flat[count].group)
            {
                immutable g = flat[count - 1].group;
                immutable placedInGroup = cast(long)(count - groupStart[g]);
                if (placedInGroup < s.footnoteMinSplit && groupStart[g] > 0)
                    count = groupStart[g];
            }
            if (i == n && count == 0 && flat.length > 0)
                count = 1;
            if (count > 0)
            {
                immutable hfn = flat[count - 1].height;
                immutable ruleTop = s.bodyBottom - hfn - s.footnoteSpaceAfter - s.footnoteRuleThickness;
                immutable stackTop = ruleTop + s.footnoteRuleThickness + s.footnoteSpaceAfter;
                PlacedItem rp;
                rp.region = Region.footnote;
                rp.kind = ItemKind.rule;
                rp.x = s.bodyX;
                rp.y = ruleTop;
                rp.width = s.footnoteRuleWidth;
                rp.height = s.footnoteRuleThickness;
                page.items ~= rp;
                // re-run the stack from stackTop
                Placer fp;
                fp.cursor = stackTop;
                fp.lineSkip = s.lineSkip;
                foreach (k; 0 .. count)
                {
                    if (k > 0 && flat[k].group != flat[k - 1].group)
                    {
                        fp.cursor += s.footnoteItemSpace;
                        fp.fresh = true;
                    }
                    const ln = src.lines[flat[k].line];
                    immutable bl = fp.line(ln.ascent, ln.depth, ln.leading);
                    foreach (ref r; ln.runs)
                        page.items ~= textItem(Region.footnote, r, bl);
                }
            }
            // carry the rest
            FnGroup[] next;
            foreach (gi, g; candidates)
            {
                immutable gs = groupStart[gi];
                immutable ge = gi + 1 < candidates.length ? groupStart[gi + 1] : flat.length;
                if (ge <= count)
                    continue;
                if (gs >= count)
                    next ~= g;
                else
                    next ~= FnGroup(g.note, g.from + cast(int)(count - gs));
            }
            footnoteSplitLines += flat.length - count;
            carried = next;
        }
        else
            carried = null;

        // step 6: float marks queue their figures
        foreach (j; i .. cut)
            if (items[j].kind == VItem.Kind.floatMark)
                queue ~= items[j].index;

        pages ~= page;
        i = cut;
    }
    return pages;
}

private size_t chooseCut(in PageSource src, ref const Settings s, const bool[] legal, size_t i, long bodyTop,
    long goal, const FnGroup[] carried)
{
    const items = src.items;
    immutable n = items.length;
    Placer pl;
    pl.cursor = bodyTop;
    pl.lineSkip = s.lineSkip;
    long lastNonGlue = bodyTop;

    // footnote stack, grown incrementally
    Placer fp;
    fp.lineSkip = s.lineSkip;
    bool haveFn = false;
    void addGroup(int note, int from)
    {
        if (haveFn)
        {
            fp.cursor += s.footnoteItemSpace;
            fp.fresh = true;
        }
        haveFn = true;
        foreach (li; src.noteLines[note - 1][from .. $])
        {
            const ln = src.lines[li];
            fp.line(ln.ascent, ln.depth, ln.leading);
        }
    }

    foreach (g; carried)
        addGroup(g.note, g.from);

    size_t best = 0;
    size_t j = i + 1;
    for (;; ++j)
    {
        if (items[j - 1].kind == VItem.Kind.forceBreak)
            return j - 1;
        const it = items[j - 1];
        final switch (it.kind)
        {
        case VItem.Kind.line:
            {
                const ln = src.lines[it.index];
                pl.line(ln.ascent, ln.depth, ln.leading);
                lastNonGlue = pl.cursor;
                foreach (no; ln.notes)
                    addGroup(no, 0);
                break;
            }
        case VItem.Kind.glue:
            pl.glue(it.h);
            break;
        case VItem.Kind.rule, VItem.Kind.row:
            pl.block(it.h);
            lastNonGlue = pl.cursor;
            break;
        case VItem.Kind.floatMark:
            lastNonGlue = pl.cursor;
            break;
        case VItem.Kind.forceBreak:
            break;
        }
        long usedTotal = lastNonGlue - bodyTop;
        if (haveFn)
        {
            immutable afn = s.footnoteSpaceBefore + s.footnoteRuleThickness + s.footnoteSpaceAfter + fp.cursor;
            usedTotal += min(afn, s.footnoteMaxHeight);
        }
        if (usedTotal <= goal && legal[j])
            best = j;
        if (usedTotal > goal || j == n)
            break;
    }
    if (best != 0)
        return best;
    for (size_t k = i + 1; k <= n; ++k)
        if (legal[k])
            return k;
    return n;
}

/// `legal[j]`: may a page break occur before item `j`?
bool[] computeLegal(const VItem[] items, ref const Settings s)
{
    immutable n = items.length;
    auto legal = new bool[n + 1];
    legal[] = true;
    legal[0] = false;
    foreach (j, ref it; items)
    {
        if (it.kind != VItem.Kind.line)
            continue;
        if (it.heading)
        {
            if (it.k != 1)
                legal[j] = false;
        }
        else if (it.k > 1)
        {
            if (!(it.k - 1 >= s.orphans && it.n - it.k + 1 >= s.widows))
                legal[j] = false;
        }
    }
    if (s.keepWithNext)
    {
        foreach (j, ref it; items)
        {
            if (!(it.kind == VItem.Kind.line && it.heading && it.k == it.n))
                continue;
            size_t x = j + 1;
            while (x < n && (items[x].kind == VItem.Kind.glue || items[x].kind == VItem.Kind.floatMark))
            {
                legal[x] = false;
                ++x;
            }
            if (x < n)
                legal[x] = false;
        }
    }
    return legal;
}
