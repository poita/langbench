/// Setting broken lines: glue distribution, alignment, output runs and the
/// vertical metrics of each line.
module typeset.setline;

import typeset.arith : fdiv, scale;
import typeset.fonts;
import typeset.hlist;
import typeset.linebreak;
import typeset.settings;

/// One placed `text` item of a line. Its baseline is the line's baseline
/// minus `raise`.
struct Run
{
    long x; ///
    int width; ///
    int size; ///
    int raise; ///
    ubyte face; ///
    string text; ///
}

/// A set line.
struct Line
{
    int runStart; /// first run in `LineStore.runs`
    int runCount; ///
    long ascent, depth; ///
    long leading; /// leading of the list the line came from
    long x0; /// x of the first item
    long endX; /// x after the last item
    int group; /// group identity
    int k; /// 1-based index in the group
    int n; /// group size
    bool heading; /// group kind is `heading`
    int headingId = -1; /// index of the heading this line starts, if any
    int fnStart; /// first footnote reference in `LineStore.fnRefs`
    int fnCount; ///
    int extraStart; /// first extra run in `LineStore.extras` (list markers, TOC leaders)
    int extraCount; ///
    int aux; /// table cells: the line number within the cell
    long relY; /// figure captions: baseline relative to the figure top
}

/// Counters the report is built from.
struct Stats
{
    long lines; ///
    long overfull; ///
    long hyphenated; ///
    long emergency; ///
    long demerits; ///
    long splitLines; /// footnote lines carried to a later page
}

/// Shared storage for all set lines.
final class LineStore
{
    Line[] lines; ///
    Run[] runs; ///
    Run[] extras; /// runs attached to a line after it was set
    int[] fnRefs; ///
    Stats stats; ///
    int nextGroup; ///
}

/// Sets the lines of `h` for the chosen `breaks` and appends them to `store`.
/// Returns the index of the first line; the count equals `breaks.length`.
int setLines(const HList h, const(int)[] breaks, const(FontSet) fonts, LineStore store, bool headingGroup)
{
    immutable firstLine = cast(int) store.lines.length;
    immutable group = store.nextGroup++;
    int prev = -1;
    immutable ctx = h.ctx;
    foreach (li, b; breaks)
    {
        immutable bool first = prev < 0;
        immutable long measure = first ? ctx.measure - ctx.firstIndent : ctx.measure;
        int from = h.nextNonGlue[prev + 1];
        if (from > b)
            from = b;
        long W = h.cw[b] - h.cw[from];
        long Y = h.cy[b] - h.cy[from];
        long Z = h.cz[b] - h.cz[from];
        immutable bool inf = h.ci[b] - h.ci[from] > 0;
        ref const pitem = h.items[b];
        immutable bool hasPre = pitem.kind == ItemKind.penalty && pitem.hasPre;
        if (hasPre)
            W += pitem.width;

        // Glue distribution mode: 0 natural, 1 stretch, 2 shrink, 3 fully shrunk.
        int mode = 0;
        long E = measure - W;
        long total = 0;
        if (!inf && ctx.alignment == Align.justify)
        {
            if (E > 0 && Y > 0)
            {
                mode = 1;
                total = Y;
            }
            else if (E < 0 && Z > 0)
            {
                if (-E <= Z)
                {
                    mode = 2;
                    total = Z;
                }
                else
                    mode = 3;
            }
        }

        Line line;
        line.runStart = cast(int) store.runs.length;
        line.leading = ctx.leading;
        line.group = group;
        line.k = cast(int)(li + 1);
        line.n = cast(int) breaks.length;
        line.heading = headingGroup;
        line.fnStart = cast(int) store.fnRefs.length;

        // First pass over the items to find x positions and widths.
        long wset = 0;
        {
            long P = 0, Cprev = 0;
            foreach (i; from .. b)
            {
                ref const it = h.items[i];
                if (it.kind == ItemKind.penalty)
                    continue;
                long w = it.width;
                if (it.kind == ItemKind.glue)
                {
                    if (it.flag)
                        w = 0;
                    else if (mode == 1 || mode == 2)
                    {
                        P += mode == 1 ? it.a : it.b;
                        immutable C = fdiv(E * P, total);
                        w += C - Cprev;
                        Cprev = C;
                    }
                    else if (mode == 3)
                        w -= it.b;
                }
                wset += w;
            }
        }
        if (hasPre)
            wset += pitem.width;
        immutable long leftLine = ctx.left + (first ? ctx.firstIndent : 0);
        long x;
        final switch (ctx.alignment)
        {
        case Align.justify:
        case Align.left:
            x = leftLine;
            break;
        case Align.right:
            x = leftLine + measure - wset;
            break;
        case Align.center:
            x = leftLine + fdiv(measure - wset, 2);
            break;
        }
        line.x0 = x;

        // Second pass: emit runs.
        long ascent = -1, depth = -1;
        int lastFrag = -1;
        int lastFace = -1, lastSize, lastRaise;
        size_t lastRun = size_t.max;
        long P = 0, Cprev = 0;
        foreach (i; from .. b)
        {
            ref const it = h.items[i];
            final switch (it.kind)
            {
            case ItemKind.box:
                if (it.width == 0 && it.face == noFace)
                {
                    lastFrag = -1;
                    break;
                }
                if (it.face == noFace)
                {
                    x += it.width;
                    lastFrag = -1;
                    break;
                }
                {
                    immutable asc = scale(fonts.faces[it.face].ascent, it.size) + it.raise;
                    long dep = scale(fonts.faces[it.face].descent, it.size) - it.raise;
                    if (dep < 0)
                        dep = 0;
                    if (asc > ascent)
                        ascent = asc;
                    if (dep > depth)
                        depth = dep;
                }
                if (it.footnote >= 0)
                    store.fnRefs ~= it.footnote;
                if (lastFrag == it.frag && lastFace == it.face && lastSize == it.size
                        && lastRaise == it.raise && lastRun != size_t.max)
                {
                    auto r = &store.runs[lastRun];
                    r.width += it.width;
                    // Boxes of one fragment are contiguous in the text buffer.
                    r.text = cast(string)(r.text ~ h.boxText(it));
                }
                else
                {
                    store.runs ~= Run(x, it.width, it.size, it.raise, it.face, h.boxText(it).idup);
                    lastRun = store.runs.length - 1;
                    lastFrag = it.frag;
                    lastFace = it.face;
                    lastSize = it.size;
                    lastRaise = it.raise;
                }
                x += it.width;
                break;
            case ItemKind.glue:
                {
                    long w = it.width;
                    if (it.flag)
                        w = 0;
                    else if (mode == 1 || mode == 2)
                    {
                        P += mode == 1 ? it.a : it.b;
                        immutable C = fdiv(E * P, total);
                        w += C - Cprev;
                        Cprev = C;
                    }
                    else if (mode == 3)
                        w -= it.b;
                    x += w;
                    lastFrag = -1;
                    break;
                }
            case ItemKind.penalty:
                break;
            }
        }
        if (hasPre)
        {
            if (lastFrag >= 0 && lastRun != size_t.max && lastFace == pitem.face
                    && lastSize == pitem.size && lastRaise == pitem.raise)
            {
                auto r = &store.runs[lastRun];
                r.width += pitem.width;
                r.text = r.text ~ "-";
            }
            else
                store.runs ~= Run(x, pitem.width, pitem.size, pitem.raise, pitem.face, "-");
            x += pitem.width;
        }
        line.runCount = cast(int) store.runs.length - line.runStart;
        line.fnCount = cast(int) store.fnRefs.length - line.fnStart;
        line.endX = x;
        if (ascent < 0)
        {
            immutable fi = faceIndex(ctx.family, ctx.bold, ctx.italic);
            ascent = scale(fonts.faces[fi].ascent, ctx.size);
            depth = scale(fonts.faces[fi].descent, ctx.size);
        }
        line.ascent = ascent;
        line.depth = depth;

        ++store.stats.lines;
        if (wset > measure)
            ++store.stats.overfull;
        if (hasPre)
            ++store.stats.hyphenated;
        store.lines ~= line;
        prev = b;
    }
    return firstLine;
}
