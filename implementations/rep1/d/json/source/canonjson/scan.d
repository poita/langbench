/**
 * Low-level byte scanning helpers shared by the validator, parser and serializer.
 */
module canonjson.scan;

import core.stdc.string : memcpy;

/// Loads 8 bytes starting at `s[i]` (requires `i + 8 <= s.length`).
ulong load64(const(ubyte)[] s, size_t i) @trusted pure nothrow @nogc
in (i + 8 <= s.length)
{
    ulong w = void;
    memcpy(&w, s.ptr + i, 8);
    return w;
}

private enum ulong ones = 0x0101010101010101UL;
private enum ulong highs = 0x8080808080808080UL;

/// Lookup table: true for the bytes that end a run of plain string content
/// (`"`, `\` and the control characters U+0000..U+001F).
immutable bool[256] stringSpecial = () {
    bool[256] t;
    foreach (i; 0 .. 0x20)
        t[i] = true;
    t['"'] = true;
    t['\\'] = true;
    return t;
}();

/**
 * Returns the index of the first byte at or after `i` that is `"`, `\` or
 * below 0x20, or `s.length` if there is none.
 *
 * Eight bytes are tested at a time; the exact byte is then found with the table.
 */
size_t skipPlain(const(ubyte)[] s, size_t i) @safe pure nothrow @nogc
{
    immutable n = s.length;
    while (i + 8 <= n)
    {
        immutable w = load64(s, i);
        immutable q = w ^ (ones * '"');
        immutable b = w ^ (ones * '\\');
        immutable hit = ((q - ones) & ~q) | ((b - ones) & ~b) | ((w - ones * 0x20) & ~w);
        if (hit & highs)
            break;
        i += 8;
    }
    while (i < n && !stringSpecial[s[i]])
        ++i;
    return i;
}
