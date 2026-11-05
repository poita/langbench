/**
 * KBL glob patterns: compilation and allocation-free matching.
 *
 * A pattern is split on `/` into components. A component is `**` (zero or
 * more whole candidate components) or a sequence of items (`*`, `?`, a
 * character class, or a literal byte). Candidates are split at every `/`.
 */
module kiln.glob;

private enum ItemKind : ubyte
{
    literal,
    anyByte,
    star,
    byteClass,
}

private struct Item
{
    ItemKind kind;
    ubyte ch;
    ulong[4] bits; // for byteClass: the set of accepted bytes (negation already applied)

    bool test(ubyte b) const @safe pure nothrow @nogc
    {
        return (bits[b >> 6] >> (b & 63)) & 1;
    }
}

private struct Component
{
    bool doubleStar;
    Item[] items;
}

/// A compiled glob pattern.
final class GlobPattern
{
    private Component[] comps;
    private bool hasDoubleStar;
    /// Leading literal components joined with `/` (no trailing `/`).
    string literalPrefix;

    // Scratch storage reused between candidates.
    private int[] starts;
    private int[] ends;
    private ubyte[] memo;
    private string cand;
    private size_t nc;

    /// Compiles `pattern`; returns null if it is malformed.
    static GlobPattern compile(string pattern)
    {
        if (pattern.length == 0)
            return null;
        auto g = new GlobPattern;
        size_t start = 0;
        bool prefixOpen = true;
        size_t prefixEnd = 0;
        foreach (i; 0 .. pattern.length + 1)
        {
            if (i != pattern.length && pattern[i] != '/')
                continue;
            if (i == start)
                return null; // empty component (also leading / trailing '/')
            auto text = pattern[start .. i];
            Component c;
            if (text == "**")
            {
                c.doubleStar = true;
                g.hasDoubleStar = true;
            }
            else if (!parseItems(text, c.items))
                return null;
            if (prefixOpen)
            {
                bool meta = false;
                foreach (b; text)
                    if (b == '*' || b == '?' || b == '[')
                        meta = true;
                if (meta)
                    prefixOpen = false;
                else
                    prefixEnd = i;
            }
            g.comps ~= c;
            start = i + 1;
        }
        g.literalPrefix = pattern[0 .. prefixEnd];
        return g;
    }

    private static bool parseItems(string text, ref Item[] items)
    {
        size_t i = 0;
        while (i < text.length)
        {
            immutable c = text[i];
            Item it;
            if (c == '*')
            {
                it.kind = ItemKind.star;
                i++;
            }
            else if (c == '?')
            {
                it.kind = ItemKind.anyByte;
                i++;
            }
            else if (c == '[')
            {
                it.kind = ItemKind.byteClass;
                size_t j = i + 1;
                bool negate = false;
                if (j < text.length && text[j] == '!')
                {
                    negate = true;
                    j++;
                }
                size_t collected = 0;
                for (;;)
                {
                    if (j >= text.length)
                        return false;
                    immutable d = cast(ubyte) text[j];
                    if (d == ']')
                    {
                        if (collected == 0)
                            return false;
                        j++;
                        break;
                    }
                    if (j + 2 < text.length && text[j + 1] == '-' && text[j + 2] != ']')
                    {
                        immutable hi = cast(ubyte) text[j + 2];
                        if (d > hi)
                            return false;
                        foreach (b; d .. hi + 1)
                            it.bits[b >> 6] |= 1UL << (b & 63);
                        j += 3;
                    }
                    else
                    {
                        it.bits[d >> 6] |= 1UL << (d & 63);
                        j++;
                    }
                    collected++;
                }
                if (negate)
                    foreach (ref w; it.bits)
                        w = ~w;
                i = j;
            }
            else
            {
                it.kind = ItemKind.literal;
                it.ch = cast(ubyte) c;
                i++;
            }
            items ~= it;
        }
        return true;
    }

    /// True iff the whole of `candidate` matches the pattern.
    bool matches(string candidate)
    {
        // Split the candidate at every '/', recording offsets only.
        cand = candidate;
        starts.length = 0;
        ends.length = 0;
        starts.assumeSafeAppend();
        ends.assumeSafeAppend();
        int s = 0;
        foreach (i; 0 .. candidate.length)
            if (candidate[i] == '/')
            {
                starts ~= s;
                ends ~= cast(int) i;
                s = cast(int)(i + 1);
            }
        starts ~= s;
        ends ~= cast(int) candidate.length;
        nc = starts.length;

        if (!hasDoubleStar)
        {
            if (nc != comps.length)
                return false;
            foreach (k; 0 .. nc)
                if (!matchComponent(comps[k].items, k))
                    return false;
            return true;
        }
        immutable need = (comps.length + 1) * (nc + 1);
        if (memo.length < need)
            memo.length = need;
        memo[0 .. need] = 0;
        return rec(0, 0);
    }

    private bool rec(size_t pi, size_t ci)
    {
        if (pi == comps.length)
            return ci == nc;
        immutable slot = pi * (nc + 1) + ci;
        if (memo[slot])
            return false;
        if (comps[pi].doubleStar)
        {
            foreach (k; ci .. nc + 1)
                if (rec(pi + 1, k))
                    return true;
        }
        else if (ci < nc && matchComponent(comps[pi].items, ci) && rec(pi + 1, ci + 1))
            return true;
        memo[slot] = 1;
        return false;
    }

    // Linear star-backtracking match of one component against one candidate component.
    private bool matchComponent(const(Item)[] items, size_t ci) const
    {
        immutable s = starts[ci];
        immutable n = ends[ci] - s;
        size_t i = 0;
        int j = 0;
        ptrdiff_t starItem = -1;
        int starJ = 0;
        while (j < n)
        {
            if (i < items.length && items[i].kind != ItemKind.star)
            {
                immutable b = cast(ubyte) cand[s + j];
                final switch (items[i].kind)
                {
                case ItemKind.literal:
                    if (items[i].ch == b)
                    {
                        i++;
                        j++;
                        continue;
                    }
                    break;
                case ItemKind.anyByte:
                    i++;
                    j++;
                    continue;
                case ItemKind.byteClass:
                    if (items[i].test(b))
                    {
                        i++;
                        j++;
                        continue;
                    }
                    break;
                case ItemKind.star:
                    assert(0);
                }
            }
            else if (i < items.length)
            {
                starItem = cast(ptrdiff_t) i;
                starJ = j;
                i++;
                continue;
            }
            if (starItem >= 0)
            {
                i = cast(size_t) starItem + 1;
                j = ++starJ;
            }
            else
                return false;
        }
        while (i < items.length && items[i].kind == ItemKind.star)
            i++;
        return i == items.length;
    }
}
