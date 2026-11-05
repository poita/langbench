/// Glob patterns: compilation and matching.
///
/// A pattern is split on `/` into components. `**` as a whole component
/// matches zero or more candidate components; other components are sequences
/// of literal bytes, `?`, `*` and character classes.
module kiln.glob;

import kiln.bytes : startsWithBytes;

/// One matching item inside a (non-`**`) component.
struct GlobItem
{
    enum Kind : ubyte { literal, any, star, cls }
    Kind kind;
    char ch;
    bool negate;
    ulong[4] set; /// 256-bit membership set for classes

    bool classHas(ubyte b) const @safe pure nothrow @nogc
    {
        immutable inSet = (set[b >> 6] >> (b & 63)) & 1;
        return negate ? !inSet : inSet != 0;
    }
}

/// One pattern component.
struct GlobComponent
{
    bool doubleStar;
    GlobItem[] items;
}

/// A compiled glob pattern.
struct GlobPattern
{
    GlobComponent[] comps;

    /// The leading literal components joined by `/` (no trailing `/`): every
    /// match starts with this byte prefix, so it narrows the search range.
    string literalPrefix() const pure
    {
        string r;
        foreach (i, ref c; comps)
        {
            if (c.doubleStar)
                break;
            char[] lit;
            foreach (ref it; c.items)
            {
                if (it.kind != GlobItem.Kind.literal)
                    return r;
                lit ~= it.ch;
            }
            if (i > 0)
                r ~= '/';
            r ~= lit;
        }
        return r;
    }
}

/// Compile `pat`. Returns false for a malformed pattern (empty, leading or
/// trailing `/`, empty component, malformed class).
bool compileGlob(const(char)[] pat, out GlobPattern result) pure nothrow
{
    result = GlobPattern.init;
    if (pat.length == 0)
        return false;
    size_t start = 0;
    foreach (i; 0 .. pat.length + 1)
    {
        if (i != pat.length && pat[i] != '/')
            continue;
        auto comp = pat[start .. i];
        if (comp.length == 0)
            return false;
        GlobComponent gc;
        if (comp == "**")
            gc.doubleStar = true;
        else if (!compileComponent(comp, gc.items))
            return false;
        result.comps ~= gc;
        start = i + 1;
    }
    return true;
}

private bool compileComponent(const(char)[] comp, ref GlobItem[] items) pure nothrow
{
    size_t i = 0;
    while (i < comp.length)
    {
        immutable c = comp[i];
        GlobItem it;
        if (c == '*')
        {
            it.kind = GlobItem.Kind.star;
            ++i;
        }
        else if (c == '?')
        {
            it.kind = GlobItem.Kind.any;
            ++i;
        }
        else if (c == '[')
        {
            it.kind = GlobItem.Kind.cls;
            ++i;
            if (i < comp.length && comp[i] == '!')
            {
                it.negate = true;
                ++i;
            }
            size_t count = 0;
            bool closed = false;
            while (true)
            {
                if (i >= comp.length)
                    return false; // unterminated
                if (comp[i] == ']')
                {
                    if (count == 0)
                        return false;
                    ++i;
                    closed = true;
                    break;
                }
                if (i + 2 < comp.length && comp[i + 1] == '-' && comp[i + 2] != ']')
                {
                    immutable lo = cast(ubyte) comp[i];
                    immutable hi = cast(ubyte) comp[i + 2];
                    if (lo > hi)
                        return false;
                    foreach (b; lo .. hi + 1)
                        it.set[b >> 6] |= 1UL << (b & 63);
                    i += 3;
                }
                else
                {
                    immutable b = cast(ubyte) comp[i];
                    it.set[b >> 6] |= 1UL << (b & 63);
                    ++i;
                }
                ++count;
            }
            if (!closed)
                return false;
        }
        else
        {
            it.kind = GlobItem.Kind.literal;
            it.ch = c;
            ++i;
        }
        items ~= it;
    }
    return true;
}

/// Match one candidate component against one pattern component's items using
/// linear star-backtracking.
private bool matchComponent(const(GlobItem)[] items, const(char)[] s) @safe pure nothrow @nogc
{
    size_t i = 0, j = 0;
    size_t starI = size_t.max, mark = 0;
    while (j < s.length)
    {
        if (i < items.length)
        {
            ref const it = items[i];
            final switch (it.kind)
            {
            case GlobItem.Kind.star:
                starI = i;
                mark = j;
                ++i;
                continue;
            case GlobItem.Kind.any:
                ++i;
                ++j;
                continue;
            case GlobItem.Kind.literal:
                if (s[j] == it.ch)
                {
                    ++i;
                    ++j;
                    continue;
                }
                break;
            case GlobItem.Kind.cls:
                if (it.classHas(cast(ubyte) s[j]))
                {
                    ++i;
                    ++j;
                    continue;
                }
                break;
            }
        }
        if (starI != size_t.max)
        {
            ++mark;
            j = mark;
            i = starI + 1;
            continue;
        }
        return false;
    }
    while (i < items.length && items[i].kind == GlobItem.Kind.star)
        ++i;
    return i == items.length;
}

/// True when `pat` matches the whole of `cand`. The candidate is split at
/// every `/` (empty components are kept) by walking offsets; nothing is
/// allocated.
bool globMatches(const ref GlobPattern pat, const(char)[] cand) @safe pure nothrow @nogc
{
    immutable n = cand.length;
    immutable P = pat.comps.length;
    size_t pi = 0;
    size_t cs = 0; // start offset of the current candidate component; n + 1 = consumed
    size_t starPi = size_t.max, starCs = 0;
    while (true)
    {
        if (pi < P)
        {
            if (pat.comps[pi].doubleStar)
            {
                starPi = pi;
                starCs = cs;
                ++pi;
                continue;
            }
            if (cs <= n)
            {
                size_t ce = cs;
                while (ce < n && cand[ce] != '/')
                    ++ce;
                if (matchComponent(pat.comps[pi].items, cand[cs .. ce]))
                {
                    ++pi;
                    cs = ce + 1;
                    continue;
                }
            }
        }
        else if (cs > n)
            return true;
        // Mismatch: let the last `**` swallow one more candidate component.
        if (starPi != size_t.max && starCs <= n)
        {
            size_t ce = starCs;
            while (ce < n && cand[ce] != '/')
                ++ce;
            starCs = ce + 1;
            cs = starCs;
            pi = starPi + 1;
            continue;
        }
        return false;
    }
}
