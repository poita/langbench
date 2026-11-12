/**
 * Ordering of strings by UTF-16 code units.
 */
module jsoncanon.order;

/**
 * Compares two well-formed UTF-8 strings as if they were UTF-16 code unit
 * sequences compared unit by unit as unsigned 16-bit integers.
 *
 * This is neither UTF-8 byte order nor code point order: supplementary
 * characters (surrogate pairs 0xD800–0xDFFF) sort before U+E000–U+FFFF.
 * No UTF-16 transcoding is done: UTF-8 byte order equals code point order, and
 * the only place where the two orders disagree is a 4-byte sequence (lead
 * byte 0xF0–0xF4) against a 3-byte sequence in U+E000–U+FFFF (lead byte 0xEE
 * or 0xEF).
 *
 * Returns: a negative number, zero, or a positive number if `a` sorts before,
 * equal to, or after `b`.
 */
int compareUtf16Order(scope const(char)[] a, scope const(char)[] b) @trusted pure nothrow @nogc
{
    immutable size_t n = a.length < b.length ? a.length : b.length;
    const(ubyte)* pa = cast(const(ubyte)*) a.ptr;
    const(ubyte)* pb = cast(const(ubyte)*) b.ptr;
    size_t i = 0;
    // Skip the common prefix, eight bytes at a time.
    while (n - i >= 8)
    {
        ulong x = void, y = void;
        (cast(ubyte*)&x)[0 .. 8] = pa[i .. i + 8];
        (cast(ubyte*)&y)[0 .. 8] = pb[i .. i + 8];
        if (x != y)
            break;
        i += 8;
    }
    for (; i < n; ++i)
    {
        immutable ubyte x = pa[i], y = pb[i];
        if (x == y)
            continue;
        // The prefixes are identical, so a differing byte is either two
        // different lead bytes or two continuation bytes of the same lead.
        immutable bool xAstral = x >= 0xF0, yAstral = y >= 0xF0;
        immutable bool xHigh = x == 0xEE || x == 0xEF, yHigh = y == 0xEE || y == 0xEF;
        if (xAstral && yHigh)
            return -1;
        if (xHigh && yAstral)
            return 1;
        return x < y ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

@safe unittest
{
    // The ordering example from the specification.
    immutable string[] ascending = [
        "", "Z", "a", "a\0", "aa", "é", "\U0001F600", "", "￿"
    ];
    foreach (i, x; ascending)
        foreach (j, y; ascending)
        {
            immutable c = compareUtf16Order(x, y);
            if (i < j)
                assert(c < 0);
            else if (i > j)
                assert(c > 0);
            else
                assert(c == 0);
        }
}

@safe unittest
{
    // Long common prefixes (exercise the word-at-a-time loop).
    assert(compareUtf16Order("aaaaaaaaaaaaaaaaaaaaX", "aaaaaaaaaaaaaaaaaaaaY") < 0);
    assert(compareUtf16Order("aaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaa") < 0);
    assert(compareUtf16Order("aaaaaaaaaaaaaaaaaaaa\U0001F600", "aaaaaaaaaaaaaaaaaaaa￿") < 0);
    // Astral vs. astral and BMP vs. BMP keep code point order.
    assert(compareUtf16Order("\U0001F600", "\U0001F601") < 0);
    assert(compareUtf16Order("\U00010000", "\U0010FFFF") < 0);
    assert(compareUtf16Order("퟿", "\U00010000") < 0);
    assert(compareUtf16Order("", "") < 0);
}
