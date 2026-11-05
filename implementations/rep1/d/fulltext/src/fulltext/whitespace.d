/**
 * The seven whitespace code points the specification recognises
 * (U+0009 … U+000D, U+0020 and U+00A0), with helpers that work directly on
 * UTF-8 code units.
 */
module fulltext.whitespace;

import std.array : appender;

/**
 * Returns the length in code units of the whitespace code point starting at
 * `s[i]` (1 for the ASCII ones, 2 for U+00A0), or 0 when there is none.
 */
size_t spaceLengthAt(T)(const(T)[] s, size_t i) pure nothrow @nogc @safe
    if (is(T == char) || is(T == ubyte))
{
    if (i >= s.length)
        return 0;
    immutable c = s[i];
    if ((c >= 9 && c <= 13) || c == 32)
        return 1;
    if (c == 0xC2 && i + 1 < s.length && s[i + 1] == 0xA0)
        return 2;
    return 0;
}

/// Strips leading and trailing whitespace (as defined above) from `s`.
inout(char)[] stripSpace(return scope inout(char)[] s) pure nothrow @nogc @safe
{
    size_t lo = 0;
    while (lo < s.length)
    {
        immutable n = spaceLengthAt(s, lo);
        if (n == 0)
            break;
        lo += n;
    }
    size_t hi = s.length;
    while (hi > lo)
    {
        if (spaceLengthAt(s, hi - 1) == 1)
            hi -= 1;
        else if (hi >= lo + 2 && spaceLengthAt(s, hi - 2) == 2)
            hi -= 2;
        else
            break;
    }
    return s[lo .. hi];
}

/// Replaces every maximal run of whitespace in `src` by a single space.
string collapseSpace(const(ubyte)[] src) pure @safe
{
    auto app = appender!(char[]);
    app.reserve(src.length);
    size_t i = 0;
    while (i < src.length)
    {
        immutable n = spaceLengthAt(src, i);
        if (n == 0)
        {
            app.put(cast(char) src[i]);
            ++i;
            continue;
        }
        while (i < src.length)
        {
            immutable m = spaceLengthAt(src, i);
            if (m == 0)
                break;
            i += m;
        }
        app.put(' ');
    }
    return (() @trusted => cast(string) app.data)();
}
