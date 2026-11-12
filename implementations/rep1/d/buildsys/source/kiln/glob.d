/**
 * Glob patterns, as used by `glob`, `filter` and `reject`.
 *
 * A pattern is split on `/` into components; `**` as a whole component
 * matches zero or more candidate components, and the remaining components
 * match exactly one candidate component made of `*`, `?`, `[...]` classes and
 * literal bytes.
 */
module kiln.glob;

/// A compiled glob pattern.
struct GlobPattern
{
    private enum ItemKind : ubyte { literal, any, star, cls }

    private struct Item
    {
        ItemKind kind;
        char ch;
        ulong[4] set; // byte membership for classes (negation already applied)
    }

    private struct Component
    {
        bool doubleStar;
        Item[] items;
    }

    private Component[] components;
    /// The wildcard-free prefix of the pattern (used to narrow index scans).
    string literalPrefix;

    /// Compiles `pattern`; returns false if it is malformed.
    static bool compile(string pattern, out GlobPattern result)
    {
        GlobPattern g;
        if (pattern.length == 0)
            return false;
        size_t start = 0;
        foreach (i; 0 .. pattern.length + 1)
        {
            if (i == pattern.length || pattern[i] == '/')
            {
                const comp = pattern[start .. i];
                if (comp.length == 0)
                    return false;
                Component c;
                if (comp == "**")
                    c.doubleStar = true;
                else if (!compileComponent(comp, c.items))
                    return false;
                g.components ~= c;
                start = i + 1;
            }
        }
        size_t p = 0;
        while (p < pattern.length && pattern[p] != '*' && pattern[p] != '?' && pattern[p] != '[')
            ++p;
        // `x/**` also matches `x` itself (`**` may match zero components), so a prefix that
        // ends right before a whole-component `**` must not require the trailing slash.
        if (p > 0 && pattern[p - 1] == '/' && pattern[p .. $].length >= 2 && pattern[p .. p + 2] == "**"
            && (p + 2 == pattern.length || pattern[p + 2] == '/'))
            --p;
        g.literalPrefix = pattern[0 .. p];
        result = g;
        return true;
    }

    /// True if the whole `candidate` matches (it is split at every `/`, keeping empty components).
    bool matches(const(char)[] candidate) const
    {
        // Split the candidate into components.
        const(char)[][] cand;
        size_t start = 0;
        foreach (i; 0 .. candidate.length + 1)
        {
            if (i == candidate.length || candidate[i] == '/')
            {
                cand ~= candidate[start .. i];
                start = i + 1;
            }
        }
        const n = cand.length;
        auto cur = new bool[n + 1];
        auto next = new bool[n + 1];
        cur[0] = true;
        foreach (ref comp; components)
        {
            next[] = false;
            if (comp.doubleStar)
            {
                bool seen = false;
                foreach (j; 0 .. n + 1)
                {
                    seen = seen || cur[j];
                    next[j] = seen;
                }
            }
            else
            {
                foreach (j; 0 .. n)
                    if (cur[j] && matchComponent(comp.items, cand[j]))
                        next[j + 1] = true;
            }
            auto t = cur;
            cur = next;
            next = t;
        }
        return cur[n];
    }

    private static bool compileComponent(const(char)[] comp, ref Item[] items)
    {
        size_t i = 0;
        while (i < comp.length)
        {
            const c = comp[i];
            if (c == '*')
            {
                items ~= Item(ItemKind.star);
                ++i;
            }
            else if (c == '?')
            {
                items ~= Item(ItemKind.any);
                ++i;
            }
            else if (c == '[')
            {
                ++i;
                bool negate = false;
                if (i < comp.length && comp[i] == '!')
                {
                    negate = true;
                    ++i;
                }
                Item it;
                it.kind = ItemKind.cls;
                size_t collected = 0;
                while (true)
                {
                    if (i >= comp.length)
                        return false; // unterminated
                    if (comp[i] == ']')
                    {
                        ++i;
                        if (collected == 0)
                            return false;
                        break;
                    }
                    if (i + 2 < comp.length && comp[i + 1] == '-' && comp[i + 2] != ']')
                    {
                        const lo = cast(ubyte) comp[i];
                        const hi = cast(ubyte) comp[i + 2];
                        if (lo > hi)
                            return false;
                        foreach (b; lo .. hi + 1)
                            it.set[b >> 6] |= 1UL << (b & 63);
                        i += 3;
                    }
                    else
                    {
                        const b = cast(ubyte) comp[i];
                        it.set[b >> 6] |= 1UL << (b & 63);
                        ++i;
                    }
                    ++collected;
                }
                if (negate)
                    foreach (ref w; it.set)
                        w = ~w;
                items ~= it;
            }
            else
            {
                Item it;
                it.kind = ItemKind.literal;
                it.ch = c;
                items ~= it;
                ++i;
            }
        }
        return true;
    }

    private static bool matchOne(ref const Item it, char c)
    {
        final switch (it.kind)
        {
        case ItemKind.literal:
            return it.ch == c;
        case ItemKind.any:
            return true;
        case ItemKind.star:
            return true;
        case ItemKind.cls:
            const b = cast(ubyte) c;
            return (it.set[b >> 6] >> (b & 63)) & 1;
        }
    }

    private static bool matchComponent(const(Item)[] items, const(char)[] s)
    {
        size_t pi = 0, si = 0;
        size_t starPi = size_t.max, starSi = 0;
        while (si < s.length)
        {
            if (pi < items.length && items[pi].kind == ItemKind.star)
            {
                starPi = pi++;
                starSi = si;
            }
            else if (pi < items.length && matchOne(items[pi], s[si]))
            {
                ++pi;
                ++si;
            }
            else if (starPi != size_t.max)
            {
                pi = starPi + 1;
                si = ++starSi;
            }
            else
                return false;
        }
        while (pi < items.length && items[pi].kind == ItemKind.star)
            ++pi;
        return pi == items.length;
    }
}

version (unittest)
{
    private bool m(string pat, string cand)
    {
        GlobPattern g;
        assert(GlobPattern.compile(pat, g), pat);
        return g.matches(cand);
    }

    private bool bad(string pat)
    {
        GlobPattern g;
        return !GlobPattern.compile(pat, g);
    }
}

unittest
{
    assert(m("src/*.txt", "src/a.txt") && m("src/*.txt", "src/.txt"));
    assert(!m("src/*.txt", "src/sub/a.txt") && !m("src/*.txt", "a.txt"));
    assert(m("src/**", "src/a.txt") && m("src/**", "src/x/y/z.txt") && m("src/**", "src"));
    assert(!m("src/**", "other/a.txt") && !m("src/**", "srcx"));
    assert(m("**/*.txt", "a.txt") && m("**/*.txt", "src/a.txt") && m("**/*.txt", "a/b/c.txt"));
    assert(!m("**/*.txt", "a.text"));
    assert(m("src/**/t_*.txt", "src/t_1.txt") && m("src/**/t_*.txt", "src/a/b/t_2.txt"));
    assert(!m("src/**/t_*.txt", "src/t.txt"));
    assert(m("src/?.txt", "src/a.txt") && !m("src/?.txt", "src/ab.txt"));
    assert(m("src/[ab]*.txt", "src/a1.txt") && m("src/[ab]*.txt", "src/b.txt") && !m("src/[ab]*.txt", "src/c.txt"));
    assert(m("src/[!ab]*.txt", "src/c.txt") && !m("src/[!ab]*.txt", "src/a.txt"));
    assert(m("src/[0-9].txt", "src/7.txt") && !m("src/[0-9].txt", "src/x.txt"));
    assert(m("a**b", "axyzb") && m("a**b", "ab") && !m("a**b", "a/b"));
}

unittest
{
    // Empty candidate components are kept.
    assert(m("*", "") && m("**", "") && !m("?", ""));
    assert(!m("*", "a//b") && m("a/*/b", "a//b"));
    assert(m("**", "x/") && m("*/*", "x/") && !m("*", "x/"));
    assert(m("[-a]", "-") && m("[a-]", "-") && m("[*?]", "*") && !m("[*?]", "a"));
}

unittest
{
    assert(bad("") && bad("/a") && bad("a/") && bad("a//b"));
    assert(bad("[]") && bad("[!]") && bad("[a") && bad("[z-a]") && bad("a[/]b"));
    assert(bad("[]a]")); // "[]" is an empty class
    GlobPattern g;
    assert(GlobPattern.compile("src/**/x*", g) && g.literalPrefix == "src");
    assert(GlobPattern.compile("src/x*", g) && g.literalPrefix == "src/x");
}
