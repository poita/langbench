/**
 * Hand-rolled decimal parsing and formatting for 64-bit integers.
 *
 * Neither routine allocates, and both handle `long.min` correctly by working
 * with an unsigned magnitude.
 */
module orderedmap.parse;

/**
 * Parses an optionally negative decimal integer starting at `pos`.
 *
 * Advances `pos` past the digits. The input is assumed well formed
 * (`-?[0-9]+`); no overflow checking is done beyond the 64-bit range.
 */
pragma(inline, true)
long parseLong(const(char)[] s, ref size_t pos) @safe pure nothrow @nogc
{
    bool neg = false;
    if (pos < s.length && s[pos] == '-')
    {
        neg = true;
        ++pos;
    }
    ulong mag = parseULong(s, pos);
    return neg ? cast(long)(0 - mag) : cast(long) mag;
}

/// Parses a non-negative decimal integer starting at `pos`, advancing `pos`.
pragma(inline, true)
ulong parseULong(const(char)[] s, ref size_t pos) @safe pure nothrow @nogc
{
    ulong mag = 0;
    while (pos < s.length)
    {
        const d = cast(uint) s[pos] - '0';
        if (d > 9)
            break;
        mag = mag * 10 + d;
        ++pos;
    }
    return mag;
}

/**
 * Writes `v` in canonical decimal into the tail of `scratch` and returns the
 * slice holding it. `scratch` must have room for 20 characters.
 */
char[] formatLong(long v, return ref char[20] scratch) @safe pure nothrow @nogc
{
    ulong mag = v < 0 ? 0 - cast(ulong) v : cast(ulong) v;
    size_t i = scratch.length;
    do
    {
        scratch[--i] = cast(char)('0' + mag % 10);
        mag /= 10;
    }
    while (mag);
    if (v < 0)
        scratch[--i] = '-';
    return scratch[i .. $];
}
