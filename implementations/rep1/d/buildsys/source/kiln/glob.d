/// Glob patterns with `*`, `?`, `[...]` classes and `**` component wildcards.
module kiln.glob;

/// A compiled glob pattern. Compile once with `GlobPattern.compile`, then call
/// `matches` for each candidate; matching does not allocate per candidate.
final class GlobPattern
{
    private enum ItemKind : ubyte
    {
        literal,
        anyByte,
        star,
        klass
    }

    private static struct Item
    {
        ItemKind kind;
        ubyte lit;
        ulong[4] bits; // class membership (already negated when needed)
    }

    private static struct Comp
    {
        bool doubleStar;
        Item[] items;
    }

    private Comp[] comps;
    private string _literalPrefix;

    // reusable scratch storage for matching
    private size_t[] starts, ends;
    private ubyte[] failed;
    private const(char)[] cand;
    private size_t nCand;

    /// Compiles `pattern`; returns null if the pattern is malformed.
    static GlobPattern compile(const(char)[] pattern) @safe
    {
        if (pattern.length == 0)
            return null;
        auto g = new GlobPattern;
        size_t start = 0;
        foreach (i; 0 .. pattern.length + 1)
        {
            if (i < pattern.length && pattern[i] != '/')
                continue;
            auto part = pattern[start .. i];
            if (part.length == 0)
                return null;
            Comp c;
            if (part == "**")
                c.doubleStar = true;
            else if (!compileComponent(part, c.items))
                return null;
            g.comps ~= c;
            start = i + 1;
        }
        g.computePrefix(pattern);
        return g;
    }

    /// The leading `/`-joined components of the pattern that contain no
    /// wildcard characters (no trailing `/`); every match starts with these bytes.
    string literalPrefix() const @safe
    {
        return _literalPrefix;
    }

    private void computePrefix(const(char)[] pattern) @safe
    {
        size_t end = 0;
        size_t start = 0;
        foreach (i; 0 .. pattern.length + 1)
        {
            if (i < pattern.length && pattern[i] != '/')
                continue;
            bool plain = true;
            foreach (c; pattern[start .. i])
                if (c == '*' || c == '?' || c == '[')
                    plain = false;
            if (!plain)
                break;
            end = i;
            start = i + 1;
        }
        _literalPrefix = pattern[0 .. end].idup;
    }

    private static bool compileComponent(const(char)[] part, ref Item[] items) @safe
    {
        size_t i = 0;
        while (i < part.length)
        {
            const c = part[i];
            Item it;
            if (c == '*')
            {
                it.kind = ItemKind.star;
                ++i;
            }
            else if (c == '?')
            {
                it.kind = ItemKind.anyByte;
                ++i;
            }
            else if (c == '[')
            {
                ++i;
                bool negate = false;
                if (i < part.length && part[i] == '!')
                {
                    negate = true;
                    ++i;
                }
                ulong[4] bits;
                size_t count = 0;
                bool closed = false;
                while (true)
                {
                    if (i >= part.length)
                        return false;
                    const b = part[i];
                    if (b == ']')
                    {
                        if (count == 0)
                            return false;
                        ++i;
                        closed = true;
                        break;
                    }
                    if (i + 2 < part.length && part[i + 1] == '-' && part[i + 2] != ']')
                    {
                        const x = cast(ubyte) b, y = cast(ubyte) part[i + 2];
                        if (x > y)
                            return false;
                        foreach (v; x .. y + 1)
                            bits[v >> 6] |= 1UL << (v & 63);
                        i += 3;
                    }
                    else
                    {
                        const v = cast(ubyte) b;
                        bits[v >> 6] |= 1UL << (v & 63);
                        ++i;
                    }
                    ++count;
                }
                assert(closed);
                if (negate)
                    foreach (ref w; bits)
                        w = ~w;
                it.kind = ItemKind.klass;
                it.bits = bits;
            }
            else
            {
                it.kind = ItemKind.literal;
                it.lit = cast(ubyte) c;
                ++i;
            }
            items ~= it;
        }
        return true;
    }

    /// True if the whole `candidate` string matches.
    bool matches(const(char)[] candidate) @safe
    {
        // split the candidate at every '/' into reusable offset arrays
        starts.length = 0;
        ends.length = 0;
        size_t s = 0;
        foreach (i; 0 .. candidate.length + 1)
        {
            if (i == candidate.length || candidate[i] == '/')
            {
                starts ~= s;
                ends ~= i;
                s = i + 1;
            }
        }
        cand = candidate;
        nCand = starts.length;
        const cells = (comps.length + 1) * (nCand + 1);
        if (failed.length < cells)
            failed.length = cells;
        failed[0 .. cells] = 0;
        return matchFrom(0, 0);
    }

    private bool matchFrom(size_t pi, size_t ci) @safe
    {
        if (pi == comps.length)
            return ci == nCand;
        const cell = pi * (nCand + 1) + ci;
        if (failed[cell])
            return false;
        bool ok = false;
        if (comps[pi].doubleStar)
        {
            foreach (k; ci .. nCand + 1)
                if (matchFrom(pi + 1, k))
                {
                    ok = true;
                    break;
                }
        }
        else if (ci < nCand && matchComponent(comps[pi].items, cand[starts[ci] .. ends[ci]]))
            ok = matchFrom(pi + 1, ci + 1);
        if (!ok)
            failed[cell] = 1;
        return ok;
    }

    private static bool itemMatches(ref const Item it, char c) @safe
    {
        final switch (it.kind)
        {
        case ItemKind.literal:
            return it.lit == cast(ubyte) c;
        case ItemKind.anyByte:
            return true;
        case ItemKind.star:
            return false;
        case ItemKind.klass:
            const v = cast(ubyte) c;
            return (it.bits[v >> 6] >> (v & 63)) & 1;
        }
    }

    private static bool matchComponent(const(Item)[] items, const(char)[] s) @safe
    {
        size_t p = 0, i = 0;
        ptrdiff_t starP = -1;
        size_t starS = 0;
        while (i < s.length)
        {
            if (p < items.length && items[p].kind == ItemKind.star)
            {
                starP = cast(ptrdiff_t) p++;
                starS = i;
            }
            else if (p < items.length && itemMatches(items[p], s[i]))
            {
                ++p;
                ++i;
            }
            else if (starP >= 0)
            {
                p = cast(size_t) starP + 1;
                i = ++starS;
            }
            else
                return false;
        }
        while (p < items.length && items[p].kind == ItemKind.star)
            ++p;
        return p == items.length;
    }
}
