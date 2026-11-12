/**
 * The `LIKE` pattern matcher.
 */
module minisql.like;

private size_t charLen(ubyte lead) @safe pure nothrow @nogc
{
    if (lead < 0xC0)
        return 1;
    if (lead < 0xE0)
        return 2;
    if (lead < 0xF0)
        return 3;
    return 4;
}

private ubyte lowerAscii(char c) @safe pure nothrow @nogc
{
    return cast(ubyte)((c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c);
}

/**
 * Matches `s` against the `LIKE` pattern `p`.
 *
 * `%` matches any run of characters (including none), `_` matches exactly one
 * character, and every other character matches itself, ignoring case for the
 * 26 ASCII letters only. The whole string must match.
 *
 * The matcher is the classic wildcard loop with a single backtrack point (the
 * most recent `%`), so it needs O(|s|·|p|) time and no extra memory.
 */
bool likeMatch(const(char)[] s, const(char)[] p) @safe pure nothrow @nogc
{
    size_t si = 0, pi = 0;
    size_t starPi = size_t.max, starSi = 0;
    while (si < s.length)
    {
        if (pi < p.length)
        {
            immutable pc = p[pi];
            if (pc == '%')
            {
                ++pi;
                starPi = pi;
                starSi = si;
                continue;
            }
            if (pc == '_')
            {
                si += charLen(s[si]);
                ++pi;
                continue;
            }
            if (lowerAscii(pc) == lowerAscii(s[si]))
            {
                ++si;
                ++pi;
                continue;
            }
        }
        if (starPi == size_t.max)
            return false;
        starSi += charLen(s[starSi]);
        si = starSi;
        pi = starPi;
    }
    while (pi < p.length && p[pi] == '%')
        ++pi;
    return pi == p.length;
}

@("LIKE wildcards and case folding")
unittest
{
    assert(likeMatch("apple", "apple"));
    assert(likeMatch("APPLE", "apple"));
    assert(likeMatch("Ab_c", "ab%"));
    assert(likeMatch("abc", "a_c"));
    assert(!likeMatch("abbc", "a_c"));
    assert(likeMatch("", "%"));
    assert(likeMatch("", ""));
    assert(!likeMatch("", "_"));
    assert(likeMatch("12345", "12%"));
    assert(likeMatch("xaybzc", "%a%b%c"));
    assert(!likeMatch("xaybzd", "%a%b%c"));
    assert(likeMatch("mississippi", "m%iss%ppi"));
    assert(!likeMatch("abc", "abcd"));
    assert(!likeMatch("abcd", "abc"));
}

@("LIKE folds ASCII only and counts characters, not bytes")
unittest
{
    assert(!likeMatch("É", "é"));
    assert(likeMatch("É", "_"));
    assert(likeMatch("éa", "_a"));
    assert(likeMatch("日本語", "日%語"));
    assert(likeMatch("日本語", "___"));
    assert(!likeMatch("日本語", "__"));
}
