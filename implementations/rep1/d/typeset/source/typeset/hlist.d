/// Horizontal lists: the boxes, glue and penalties built from an inline text,
/// including fragment formation, the sentence rule and hyphenation points.
module typeset.hlist;

import typeset.arith : scale, toDecimal;
import typeset.fonts;
import typeset.hyphen : PatternSet;
import typeset.markup;
import typeset.settings;
import typeset.values : putUtf8;

/// Kinds of horizontal-list items.
enum ItemKind : ubyte
{
    box,
    glue,
    penalty,
}

/// One item of a horizontal list. Which fields apply depends on `kind`:
/// a box uses face/size/raise/width/text/frag/footnote; glue uses width
/// (natural), `a` (stretch), `b` (shrink) and `flag` (infinite); a penalty
/// uses `a` (the value), `flag` (flagged) and, when `hasPre`, the pre-break
/// hyphen described by face/size/raise/width.
struct Item
{
    ItemKind kind; ///
    bool flag; ///
    bool hasPre; ///
    ubyte face = noFace; ///
    int size; ///
    int raise; ///
    int width; ///
    int a; ///
    int b; ///
    int textOff; /// offset of the box text in `HList.text`
    int textLen; ///
    int frag = -1; /// fragment id (boxes with text)
    int footnote = -1; /// footnote id for a reference mark box
}

/// Everything a horizontal list is built and set against.
struct HContext
{
    Family family; ///
    bool bold, italic; ///
    long size; ///
    long leading; ///
    long left; ///
    long measure; ///
    long firstIndent; ///
    Align alignment; ///
    bool hyphenate; ///
}

/// A built horizontal list together with its prefix sums.
final class HList
{
    Item[] items; ///
    char[] text; /// UTF-8 text of all boxes
    HContext ctx; ///
    // Prefix sums over items [0, i): width, stretch, shrink, infinite-glue count.
    long[] cw, cy, cz; ///
    int[] ci; ///
    int[] nextNonGlue; /// smallest index >= i holding a non-glue item
    int[] breakpoints; /// item indices of the breakpoints, ascending

    /// Index of the final (forced) breakpoint.
    int finalBreak() const pure nothrow @nogc @safe
    {
        return cast(int) items.length - 1;
    }

    /// Computes prefix sums, skip table and breakpoint list.
    void finish()
    {
        immutable n = items.length;
        cw = new long[n + 1];
        cy = new long[n + 1];
        cz = new long[n + 1];
        ci = new int[n + 1];
        nextNonGlue = new int[n + 2];
        foreach (i, ref it; items)
        {
            long w, y, z;
            int inf;
            final switch (it.kind)
            {
            case ItemKind.box:
                w = it.width;
                break;
            case ItemKind.glue:
                w = it.width;
                y = it.a;
                z = it.b;
                inf = it.flag ? 1 : 0;
                break;
            case ItemKind.penalty:
                break;
            }
            cw[i + 1] = cw[i] + w;
            cy[i + 1] = cy[i] + y;
            cz[i + 1] = cz[i] + z;
            ci[i + 1] = ci[i] + inf;
        }
        nextNonGlue[n] = cast(int) n;
        nextNonGlue[n + 1] = cast(int) n;
        for (int i = cast(int) n - 1; i >= 0; --i)
            nextNonGlue[i] = items[i].kind != ItemKind.glue ? i : nextNonGlue[i + 1];
        breakpoints = null;
        foreach (i, ref it; items)
        {
            if (it.kind == ItemKind.glue)
            {
                if (i > 0 && items[i - 1].kind == ItemKind.box)
                    breakpoints ~= cast(int) i;
            }
            else if (it.kind == ItemKind.penalty && it.a < 10000)
                breakpoints ~= cast(int) i;
        }
    }

    /// Natural width of the whole list on one line (the final glue has width 0).
    long naturalWidth() const pure nothrow @nogc @safe
    {
        return cw[$ - 1];
    }

    /// The text of a box item.
    const(char)[] boxText(ref const Item it) const pure nothrow @nogc @safe
    {
        return text[it.textOff .. it.textOff + it.textLen];
    }

    /// The width `W` of the line between breakpoints `a` (or -1 for the start)
    /// and `b`, leading glue removed and pre-break text included.
    long lineWidth(int a, int b) const pure nothrow @nogc @safe
    {
        int first = nextNonGlue[a + 1];
        if (first > b)
            first = b;
        long w = cw[b] - cw[first];
        if (items[b].kind == ItemKind.penalty && items[b].hasPre)
            w += items[b].width;
        return w;
    }
}

/// Collaborators needed to build horizontal lists.
struct BuildEnv
{
    FontSet fonts; ///
    const(Settings)* settings; ///
    PatternSet patterns; ///
}

private bool isLetter(uint c) pure nothrow @nogc @safe
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/// Sentence-ending test for the glue at `units[idx]`.
bool followsSentenceEnd(const(Unit)[] units, size_t idx) pure nothrow @nogc @safe
{
    static bool skippable(uint c)
    {
        switch (c)
        {
        case ')', ']', '}', '\'', '"', 0x2019, 0x201D:
            return true;
        default:
            return false;
        }
    }

    long k = cast(long) idx - 1;
    while (k >= 0)
    {
        immutable u = units[k];
        if (u.kind == UnitKind.disc || (u.kind == UnitKind.chr && skippable(u.value)))
            --k;
        else
            break;
    }
    if (k < 0 || units[k].kind != UnitKind.chr)
        return false;
    immutable p = units[k].value;
    if (p != '.' && p != '!' && p != '?')
        return false;
    --k;
    while (k >= 0 && units[k].kind == UnitKind.disc)
        --k;
    if (k >= 0 && units[k].kind == UnitKind.chr && units[k].value >= 'A' && units[k].value <= 'Z')
        return false;
    return true;
}

/// Builds horizontal lists; keeps scratch buffers between builds.
struct HListBuilder
{
    BuildEnv env; ///

    private
    {
        uint[] fcps;
        int[] fdiscs;
        ubyte[] points;
        char[] lower;
        int fFace, fSize, fRaise;
        int nextFrag;
        HList h;
        const(Settings)* s;
        bool hyphOk;
    }

    /// Builds the list for `inl` in context `ctx`.
    HList build(const ref Inline inl, in HContext ctx)
    {
        s = env.settings;
        h = new HList;
        h.ctx = ctx;
        hyphOk = ctx.hyphenate && s.hyphenate && env.patterns !is null;
        nextFrag = 0;
        fcps.length = 0;
        fdiscs.length = 0;

        // Resolve every style node against the context's initial style.
        immutable nStyles = inl.styles.length > 0 ? inl.styles.length : 1;
        struct Res
        {
            Family fam;
            bool bold, italic;
            long size;
        }

        auto res = new Res[nStyles];
        res[0] = Res(ctx.family, ctx.bold, ctx.italic, ctx.size);
        foreach (i; 1 .. nStyles)
        {
            auto node = inl.styles[i];
            auto r = res[node.parent];
            final switch (node.op)
            {
            case StyleOp.root:
                break;
            case StyleOp.bold:
                r.bold = true;
                break;
            case StyleOp.italic:
                r.italic = true;
                break;
            case StyleOp.mono:
                r.fam = Family.mono;
                break;
            case StyleOp.up:
                r.size = (r.size * 6) / 5;
                break;
            case StyleOp.down:
                r.size = (r.size * 5) / 6;
                break;
            }
            res[i] = r;
        }

        immutable ragged = ctx.alignment != Align.justify;
        bool prevIsChar = false;
        const(Unit)[] units = inl.units;
        foreach (idx, u; units)
        {
            immutable r = res[u.style < nStyles ? u.style : 0];
            immutable face = faceIndex(r.fam, r.bold, r.italic);
            final switch (u.kind)
            {
            case UnitKind.chr:
                if (fcps.length && (fFace != face || fSize != r.size || fRaise != 0))
                    flushFragment();
                if (fcps.length == 0)
                {
                    fFace = face;
                    fSize = cast(int) r.size;
                    fRaise = 0;
                }
                fcps ~= u.value;
                prevIsChar = true;
                break;
            case UnitKind.disc:
                if (prevIsChar && fcps.length)
                    fdiscs ~= cast(int) fcps.length;
                break;
            case UnitKind.glue:
            case UnitKind.glueOrdinary:
                flushFragment();
                prevIsChar = false;
                {
                    ref const f = env.fonts.faces[face];
                    immutable extra = u.kind == UnitKind.glue && followsSentenceEnd(units, idx);
                    Item g;
                    g.kind = ItemKind.glue;
                    if (extra)
                    {
                        g.width = cast(int) scale(f.space + f.extra, r.size);
                        g.a = cast(int) scale(f.stretch + f.stretch / 2, r.size);
                        g.b = cast(int) scale(f.shrink, r.size);
                    }
                    else
                    {
                        g.width = cast(int) scale(f.space, r.size);
                        g.a = cast(int) scale(f.stretch, r.size);
                        g.b = cast(int) scale(f.shrink, r.size);
                    }
                    if (ragged)
                    {
                        g.a = cast(int)(s.raggedStretch * g.width);
                        g.b = 0;
                    }
                    h.items ~= g;
                }
                break;
            case UnitKind.rigid:
                flushFragment();
                prevIsChar = false;
                {
                    Item b;
                    b.kind = ItemKind.box;
                    b.width = cast(int) scale(env.fonts.faces[face].space, r.size);
                    h.items ~= b;
                }
                break;
            case UnitKind.rigidFixed:
                flushFragment();
                prevIsChar = false;
                {
                    Item b;
                    b.kind = ItemKind.box;
                    b.width = cast(int) u.value;
                    h.items ~= b;
                }
                break;
            case UnitKind.mark:
                flushFragment();
                prevIsChar = false;
                {
                    Item b;
                    b.kind = ItemKind.box;
                    b.face = face;
                    b.size = cast(int) s.markSize;
                    b.raise = cast(int) s.markRaise;
                    immutable txt = toDecimal(u.value + 1);
                    b.textOff = cast(int) h.text.length;
                    b.textLen = cast(int) txt.length;
                    h.text ~= txt;
                    uint[8] digits;
                    foreach (k, ch; txt)
                        digits[k] = ch;
                    b.width = cast(int) env.fonts.faces[face].width(digits[0 .. txt.length], b.size);
                    b.frag = nextFrag++;
                    b.footnote = u.value;
                    h.items ~= b;
                }
                break;
            }
        }
        flushFragment();

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
        auto result = h;
        h = null;
        return result;
    }

    private void addBox(size_t from, size_t to)
    {
        Item b;
        b.kind = ItemKind.box;
        b.face = cast(ubyte) fFace;
        b.size = fSize;
        b.raise = fRaise;
        b.textOff = cast(int) h.text.length;
        char[] tmp;
        foreach (c; fcps[from .. to])
            putUtf8(tmp, c);
        h.text ~= tmp;
        b.textLen = cast(int) tmp.length;
        b.width = cast(int) env.fonts.faces[fFace].width(fcps[from .. to], fSize);
        b.frag = nextFrag;
        h.items ~= b;
    }

    private void flushFragment()
    {
        immutable n = fcps.length;
        if (n == 0)
        {
            fdiscs.length = 0;
            return;
        }
        bool anyLetter;
        foreach (c; fcps)
            if (isLetter(c))
            {
                anyLetter = true;
                break;
            }
        points.length = n + 1;
        points[] = 0;
        bool any;
        if (hyphOk && fFace != monoFace && anyLetter)
        {
            // Core: strip the non-letter prefix and suffix.
            size_t lo = 0, hi = n;
            while (lo < n && !isLetter(fcps[lo]))
                ++lo;
            while (hi > lo && !isLetter(fcps[hi - 1]))
                --hi;
            bool explicit;
            foreach (d; fdiscs)
                if (d > 0 && d < cast(int) n)
                    explicit = true;
            foreach (p; lo .. hi)
                if (fcps[p] == '-')
                {
                    points[p + 1] = 1;
                    any = true;
                }
            if (explicit)
            {
                foreach (d; fdiscs)
                    if (d > 0 && d < cast(int) n && points[d] == 0)
                    {
                        points[d] = 2;
                        any = true;
                    }
            }
            else
            {
                size_t segStart = lo;
                foreach (p; lo .. hi + 1)
                {
                    if (p == hi || fcps[p] == '-')
                    {
                        if (p > segStart)
                        {
                            bool allLetters = true;
                            lower.length = p - segStart;
                            foreach (k; segStart .. p)
                            {
                                immutable c = fcps[k];
                                if (!isLetter(c))
                                {
                                    allLetters = false;
                                    break;
                                }
                                lower[k - segStart] = cast(char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
                            }
                            if (allLetters)
                                foreach (q; env.patterns.hyphenate(lower))
                                {
                                    points[segStart + q] = 3;
                                    any = true;
                                }
                        }
                        segStart = p + 1;
                    }
                }
            }
        }
        if (!any)
        {
            addBox(0, n);
        }
        else
        {
            size_t start = 0;
            foreach (p; 1 .. n)
            {
                immutable kind = points[p];
                if (kind == 0)
                    continue;
                addBox(start, p);
                start = p;
                Item pen;
                pen.kind = ItemKind.penalty;
                pen.flag = true;
                if (kind == 1)
                    pen.a = cast(int) s.exHyphenPenalty;
                else
                {
                    pen.a = cast(int) s.hyphenPenalty;
                    pen.hasPre = true;
                    pen.face = cast(ubyte) fFace;
                    pen.size = fSize;
                    pen.raise = fRaise;
                    pen.width = cast(int) scale(env.fonts.faces[fFace].adv('-'), fSize);
                }
                h.items ~= pen;
            }
            addBox(start, n);
        }
        ++nextFrag;
        fcps.length = 0;
        fdiscs.length = 0;
    }
}
