/**
 * Setting a line: glue distribution, horizontal placement, output runs and
 * the vertical metrics of the line.
 */
module typeset.line;

import std.conv : to;

import typeset.hlist : Item;
import typeset.linebreak;
import typeset.metrics;
import typeset.settings : Align;
import typeset.units;

/// A run of glyphs placed on a line: one `text` item of the output.
struct Run
{
    ubyte face;
    long size;
    long raise;
    long x; /// left edge
    long width;
    string text;
}

/// One set line of text.
struct Line
{
    Run[] runs;
    long ascent, depth;
    long leading; /// baseline distance of the list this line belongs to
    long startX; /// x of the first item
    long endX; /// x after the last item
    int[] notes; /// footnotes referenced by the line, in order
    bool overfull;
    bool hyphenated;
    int headingId = -1; /// index of the heading this line starts, else -1
}

/// Where a list's lines go and how they are aligned.
struct LineContext
{
    long left; /// x of every line's left edge
    long measure;
    long firstIndent;
    Align alignment;
    ubyte face; /// initial face (for a line with no text boxes)
    long size; /// initial size
    long leading;
}

/// Distributes `total` over weights `w` with floor division: glue i gets
/// `C_i - C_{i-1}` where `C_i = (total * P_i) div T`.
long[] distribute(long total, const long[] w)
{
    long t = 0;
    foreach (x; w)
        t += x;
    auto result = new long[w.length];
    long p = 0, cPrev = 0;
    foreach (i, x; w)
    {
        p += x;
        immutable c = fdiv(total * p, t);
        result[i] = c - cPrev;
        cPrev = c;
    }
    return result;
}

/// Sets the line between breakpoints `a` and `b` of `items`.
Line setLine(const(Item)[] items, ref const ListMetrics m, int a, int b, in LineContext ctx,
    const FaceSet faces)
{
    immutable s = m.lineStart(a, b);
    immutable L = a == 0 ? ctx.measure - ctx.firstIndent : ctx.measure;
    immutable leftLine = a == 0 ? ctx.left + ctx.firstIndent : ctx.left;

    // natural sums
    long W = 0, Y = 0, Z = 0;
    bool inf = false;
    foreach (i; s .. b)
    {
        const it = items[i];
        if (it.kind == Item.Kind.box)
            W += it.width;
        else if (it.kind == Item.Kind.glue)
        {
            W += it.width;
            Y += it.stretch;
            Z += it.shrink;
            inf = inf || it.infinite;
        }
    }
    const pb = items[b];
    immutable hasPre = pb.kind == Item.Kind.penalty && pb.preText.length > 0;
    if (hasPre)
        W += pb.preWidth;

    // glue widths
    long[] gw;
    foreach (i; s .. b)
        if (items[i].kind == Item.Kind.glue)
            gw ~= items[i].width;
    if (inf)
    {
        size_t k = 0;
        foreach (i; s .. b)
            if (items[i].kind == Item.Kind.glue)
            {
                if (items[i].infinite)
                    gw[k] = 0;
                ++k;
            }
    }
    else if (ctx.alignment == Align.justify)
    {
        immutable E = L - W;
        if (E > 0 && Y > 0)
        {
            long[] weights;
            foreach (i; s .. b)
                if (items[i].kind == Item.Kind.glue)
                    weights ~= items[i].stretch;
            auto inc = distribute(E, weights);
            foreach (k, v; inc)
                gw[k] += v;
        }
        else if (E < 0 && Z > 0)
        {
            if (-E <= Z)
            {
                long[] weights;
                foreach (i; s .. b)
                    if (items[i].kind == Item.Kind.glue)
                        weights ~= items[i].shrink;
                auto inc = distribute(E, weights);
                foreach (k, v; inc)
                    gw[k] += v;
            }
            else
            {
                size_t k = 0;
                foreach (i; s .. b)
                    if (items[i].kind == Item.Kind.glue)
                        gw[k++] -= items[i].shrink;
            }
        }
    }

    long wset = 0;
    foreach (v; gw)
        wset += v;
    foreach (i; s .. b)
        if (items[i].kind == Item.Kind.box)
            wset += items[i].width;
    if (hasPre)
        wset += pb.preWidth;

    long x;
    final switch (ctx.alignment)
    {
    case Align.justify, Align.left:
        x = leftLine;
        break;
    case Align.right:
        x = leftLine + L - wset;
        break;
    case Align.center:
        x = leftLine + fdiv(L - wset, 2);
        break;
    }

    Line line;
    line.leading = ctx.leading;
    line.startX = x;
    line.endX = x + wset;
    line.overfull = wset > L;
    line.hyphenated = hasPre;

    bool anyBox = false;
    long ascent = 0, depth = 0;
    int lastFrag = -1;
    size_t gi = 0;

    void account(ubyte face, long size, long raise)
    {
        const f = faces[face];
        immutable asc = scale(f.ascent, size) + raise;
        immutable dep = scale(f.descent, size) - raise;
        if (!anyBox || asc > ascent)
            ascent = asc;
        immutable d = dep > 0 ? dep : 0;
        if (!anyBox || d > depth)
            depth = d;
        anyBox = true;
    }

    foreach (i; s .. b)
    {
        const it = items[i];
        final switch (it.kind)
        {
        case Item.Kind.glue:
            x += gw[gi++];
            lastFrag = -1;
            break;
        case Item.Kind.penalty:
            break;
        case Item.Kind.box:
            if (it.rigid)
            {
                x += it.width;
                lastFrag = -1;
                break;
            }
            account(it.face, it.size, it.raise);
            if (it.note)
                line.notes ~= it.note;
            if (lastFrag == it.frag && line.runs.length && line.runs[$ - 1].face == it.face
                && line.runs[$ - 1].size == it.size && line.runs[$ - 1].raise == it.raise)
            {
                line.runs[$ - 1].text ~= it.text.to!string;
                line.runs[$ - 1].width += it.width;
            }
            else
                line.runs ~= Run(it.face, it.size, it.raise, x, it.width, it.text.to!string);
            lastFrag = it.frag;
            x += it.width;
            break;
        }
    }
    if (hasPre)
    {
        if (lastFrag == pb.frag && line.runs.length)
        {
            line.runs[$ - 1].text ~= pb.preText.to!string;
            line.runs[$ - 1].width += pb.preWidth;
        }
        else
            line.runs ~= Run(pb.face, pb.size, pb.raise, x, pb.preWidth, pb.preText.to!string);
        x += pb.preWidth;
    }
    if (anyBox)
    {
        line.ascent = ascent;
        line.depth = depth;
    }
    else
    {
        const f = faces[ctx.face];
        line.ascent = scale(f.ascent, ctx.size);
        line.depth = scale(f.descent, ctx.size);
    }
    return line;
}

unittest
{
    // Example 4: six glues of 2540/1270/850 shrunk by 3890.
    auto inc = distribute(-3890, [850L, 850, 850, 850, 850, 850]);
    assert(inc == [-649L, -648, -648, -649, -648, -648]);
}
