/// SQL LIKE matching on UTF-8 bytes.
module minisql.like;

private char fold(char c) pure nothrow @nogc @safe
{
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

private size_t seqLen(char lead) pure nothrow @nogc @safe
{
    immutable b = cast(ubyte) lead;
    if (b < 0xC0)
        return 1;
    if (b < 0xE0)
        return 2;
    if (b < 0xF0)
        return 3;
    return 4;
}

/// Matches `s` against the LIKE pattern `p`.
///
/// `%` matches any run of characters, `_` matches exactly one character (a
/// whole UTF-8 sequence), anything else matches itself; only the 26 ASCII
/// letters are case-insensitive. Runs in O(|s|·|p|) worst case with a single
/// backtrack point and does not allocate.
bool likeMatch(const(char)[] s, const(char)[] p) pure nothrow @nogc @safe
{
    size_t si = 0, pi = 0;
    size_t starP = size_t.max, starS = 0;
    while (si < s.length)
    {
        if (pi < p.length && p[pi] == '%')
        {
            starP = pi++;
            starS = si;
            continue;
        }
        if (pi < p.length && p[pi] == '_')
        {
            si += seqLen(s[si]);
            pi++;
            continue;
        }
        if (pi < p.length && fold(p[pi]) == fold(s[si]))
        {
            si++;
            pi++;
            continue;
        }
        if (starP == size_t.max)
            return false;
        pi = starP + 1;
        starS += seqLen(s[starS]);
        si = starS;
    }
    while (pi < p.length && p[pi] == '%')
        pi++;
    return pi == p.length;
}
