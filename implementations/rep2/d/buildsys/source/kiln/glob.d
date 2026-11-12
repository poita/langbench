/**
 * Glob patterns, as used by `glob`, `filter` and `reject`.
 *
 * A pattern is compiled once into a $(LREF GlobPattern) and can then be matched
 * against many candidate strings. Matching works on bytes and on
 * `/`-separated components; `**` as a whole component matches zero or more
 * components.
 */
module kiln.glob;

private enum ItemKind : ubyte
{
    literal,
    anyByte, // ?
    star, // *
    charClass, // [...]
}

private struct Item
{
    ItemKind kind;
    char ch;
    bool negate;
    ulong[4] bits; // class membership, one bit per byte value
}

private struct Component
{
    bool doubleStar;
    Item[] items;
}

/// A compiled glob pattern.
struct GlobPattern
{
    private Component[] comps;
    /**
     * The wildcard-free prefix of the pattern text: every matching string
     * starts with it, which lets callers narrow a sorted index by binary
     * search.
     */
    string prefix;

    /// Whether the pattern matches the whole candidate string.
    bool matches(const(char)[] candidate) const @safe pure nothrow
    {
        // Split the candidate at every '/', keeping empty components.
        const(char)[][] parts;
        size_t start = 0;
        foreach (i; 0 .. candidate.length)
        {
            if (candidate[i] == '/')
            {
                parts ~= candidate[start .. i];
                start = i + 1;
            }
        }
        parts ~= candidate[start .. $];
        return matchComponents(parts);
    }

    private bool matchComponents(const(char)[][] cand) const @safe pure nothrow
    {
        immutable np = comps.length, nc = cand.length;
        size_t pi = 0, ci = 0;
        ptrdiff_t starPi = -1;
        size_t starCi = 0;
        while (ci < nc)
        {
            if (pi < np && comps[pi].doubleStar)
            {
                starPi = cast(ptrdiff_t) pi;
                starCi = ci;
                pi++;
                continue;
            }
            if (pi < np && matchItems(comps[pi].items, cand[ci]))
            {
                pi++;
                ci++;
                continue;
            }
            if (starPi >= 0)
            {
                starCi++;
                ci = starCi;
                pi = cast(size_t) starPi + 1;
                continue;
            }
            return false;
        }
        while (pi < np && comps[pi].doubleStar)
            pi++;
        return pi == np;
    }
}

private bool inClass(const ref Item it, ubyte b) @safe pure nothrow @nogc
{
    immutable inSet = (it.bits[b >> 6] >> (b & 63)) & 1;
    return it.negate ? !inSet : inSet != 0;
}

private bool matchOne(const ref Item it, char c) @safe pure nothrow @nogc
{
    final switch (it.kind)
    {
    case ItemKind.literal:
        return c == it.ch;
    case ItemKind.anyByte:
        return true; // components never contain '/'
    case ItemKind.charClass:
        return inClass(it, cast(ubyte) c);
    case ItemKind.star:
        assert(0);
    }
}

private bool matchItems(const(Item)[] items, const(char)[] s) @safe pure nothrow @nogc
{
    size_t pi = 0, si = 0;
    ptrdiff_t starPi = -1;
    size_t starSi = 0;
    while (si < s.length)
    {
        if (pi < items.length && items[pi].kind == ItemKind.star)
        {
            starPi = cast(ptrdiff_t) pi;
            starSi = si;
            pi++;
            continue;
        }
        if (pi < items.length && matchOne(items[pi], s[si]))
        {
            pi++;
            si++;
            continue;
        }
        if (starPi >= 0)
        {
            starSi++;
            si = starSi;
            pi = cast(size_t) starPi + 1;
            continue;
        }
        return false;
    }
    while (pi < items.length && items[pi].kind == ItemKind.star)
        pi++;
    return pi == items.length;
}

/**
 * Compiles `pattern`. Returns false when the pattern is malformed: empty, a
 * leading or trailing `/`, an empty component, or a malformed character class.
 */
bool compileGlob(string pattern, out GlobPattern result) @safe pure nothrow
{
    if (pattern.length == 0)
        return false;
    GlobPattern gp;
    size_t start = 0;
    foreach (i; 0 .. pattern.length + 1)
    {
        if (i == pattern.length || pattern[i] == '/')
        {
            auto text = pattern[start .. i];
            start = i + 1;
            if (text.length == 0)
                return false;
            Component c;
            if (text == "**")
                c.doubleStar = true;
            else if (!compileComponent(text, c.items))
                return false;
            gp.comps ~= c;
        }
    }
    size_t p = 0;
    while (p < pattern.length && pattern[p] != '*' && pattern[p] != '?' && pattern[p] != '[')
        p++;
    // A trailing `**` also matches zero components, so `a/**` matches `a`
    // itself: its prefix must not include the separator.
    if (p > 0 && pattern[p - 1] == '/' && pattern[p .. $] == "**")
        p--;
    gp.prefix = pattern[0 .. p];
    result = gp;
    return true;
}

private bool compileComponent(string text, ref Item[] items) @safe pure nothrow
{
    size_t i = 0;
    while (i < text.length)
    {
        immutable c = text[i];
        if (c == '*')
        {
            Item it;
            it.kind = ItemKind.star;
            // Collapse runs of stars.
            if (items.length == 0 || items[$ - 1].kind != ItemKind.star)
                items ~= it;
            i++;
        }
        else if (c == '?')
        {
            Item it;
            it.kind = ItemKind.anyByte;
            items ~= it;
            i++;
        }
        else if (c == '[')
        {
            Item it;
            it.kind = ItemKind.charClass;
            i++;
            if (i < text.length && text[i] == '!')
            {
                it.negate = true;
                i++;
            }
            size_t collected = 0;
            bool closed = false;
            while (true)
            {
                if (i >= text.length)
                    return false; // unterminated
                if (text[i] == ']')
                {
                    if (collected == 0)
                        return false;
                    i++;
                    closed = true;
                    break;
                }
                if (i + 2 < text.length && text[i + 1] == '-' && text[i + 2] != ']')
                {
                    immutable lo = cast(ubyte) text[i], hi = cast(ubyte) text[i + 2];
                    if (lo > hi)
                        return false;
                    foreach (b; lo .. hi + 1)
                        it.bits[b >> 6] |= 1UL << (b & 63);
                    i += 3;
                }
                else
                {
                    immutable b = cast(ubyte) text[i];
                    it.bits[b >> 6] |= 1UL << (b & 63);
                    i++;
                }
                collected++;
            }
            assert(closed);
            items ~= it;
        }
        else
        {
            Item it;
            it.kind = ItemKind.literal;
            it.ch = c;
            items ~= it;
            i++;
        }
    }
    return true;
}

/// Convenience used by tests: compile and match in one go.
bool globMatches(string pattern, string candidate) @safe pure nothrow
{
    GlobPattern p;
    return compileGlob(pattern, p) && p.matches(candidate);
}

@safe pure nothrow unittest
{
    assert(globMatches("src/*.txt", "src/a.txt"));
    assert(globMatches("src/*.txt", "src/.txt"));
    assert(!globMatches("src/*.txt", "src/sub/a.txt"));
    assert(!globMatches("src/*.txt", "a.txt"));
    assert(globMatches("src/**", "src/a.txt"));
    assert(globMatches("src/**", "src/x/y/z.txt"));
    assert(globMatches("src/**", "src"));
    assert(!globMatches("src/**", "srcx"));
    assert(globMatches("**/*.txt", "a.txt"));
    assert(globMatches("**/*.txt", "a/b/c.txt"));
    assert(!globMatches("**/*.txt", "a.text"));
    assert(globMatches("src/**/t_*.txt", "src/t_1.txt"));
    assert(globMatches("src/**/t_*.txt", "src/a/b/t_2.txt"));
    assert(!globMatches("src/**/t_*.txt", "src/t.txt"));
    assert(globMatches("src/?.txt", "src/a.txt"));
    assert(!globMatches("src/?.txt", "src/ab.txt"));
    assert(globMatches("src/[ab]*.txt", "src/a1.txt"));
    assert(!globMatches("src/[ab]*.txt", "src/c.txt"));
    assert(globMatches("src/[!ab]*.txt", "src/c.txt"));
    assert(globMatches("src/[0-9].txt", "src/7.txt"));
    assert(globMatches("a**b", "axyzb") && globMatches("a**b", "ab"));
    assert(!globMatches("a**b", "a/b"));
    // Candidates keep empty components.
    assert(globMatches("*", "") && globMatches("**", "") && !globMatches("?", ""));
    assert(!globMatches("*", "a//b"));
    assert(globMatches("a/*", "a/"));
    // Character-class corner cases.
    assert(globMatches("[-a]", "-") && globMatches("[a-]", "-") && globMatches("[*?]", "*"));
    GlobPattern p;
    assert(!compileGlob("", p) && !compileGlob("/a", p) && !compileGlob("a/", p));
    assert(!compileGlob("a//b", p) && !compileGlob("[]", p) && !compileGlob("[!]", p));
    assert(!compileGlob("[a", p) && !compileGlob("[z-a]", p));
    assert(compileGlob("src/a*b", p) && p.prefix == "src/a");
    assert(compileGlob("lib/**", p) && p.prefix == "lib");
    assert(compileGlob("lib/**/x", p) && p.prefix == "lib/");
}
