/**
 * Minimal, allocation-free decimal parsing and formatting for 64-bit integers.
 */
module orderedmap.numbers;

/// Thrown when text is not a valid decimal integer in range.
class NumberFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/**
 * Parses an optionally negative decimal integer occupying all of `s`.
 *
 * Accepts the full `long` range including `long.min`.
 *
 * Throws: `NumberFormatException` on empty input, stray characters or overflow.
 */
long parseLong(const(char)[] s) @safe pure
{
    bool neg = false;
    size_t i = 0;
    if (s.length && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i == s.length)
        throw new NumberFormatException("expected a decimal integer");
    ulong v = 0;
    for (; i < s.length; ++i)
    {
        immutable d = s[i] - '0';
        if (d < 0 || d > 9)
            throw new NumberFormatException("invalid digit in integer");
        if (v > (ulong.max - d) / 10)
            throw new NumberFormatException("integer out of range");
        v = v * 10 + d;
    }
    immutable limit = neg ? cast(ulong) long.max + 1 : cast(ulong) long.max;
    if (v > limit)
        throw new NumberFormatException("integer out of range");
    return neg ? cast(long)(0 - v) : cast(long) v;
}

/**
 * Parses a non-negative decimal integer occupying all of `s`.
 *
 * Throws: `NumberFormatException` if `s` is not a valid `ulong`.
 */
ulong parseUlong(const(char)[] s) @safe pure
{
    if (s.length == 0)
        throw new NumberFormatException("expected a decimal integer");
    ulong v = 0;
    foreach (c; s)
    {
        immutable d = c - '0';
        if (d < 0 || d > 9)
            throw new NumberFormatException("invalid digit in integer");
        if (v > (ulong.max - d) / 10)
            throw new NumberFormatException("integer out of range");
        v = v * 10 + d;
    }
    return v;
}

/// Maximum characters needed by $(LREF formatLong) (`-9223372036854775808`).
enum maxLongChars = 20;

/**
 * Writes the canonical decimal form of `v` into the end of `buf`.
 *
 * Returns: the slice of `buf` holding the digits.
 */
char[] formatLong(return ref char[maxLongChars] buf, long v) @safe pure nothrow @nogc
{
    ulong u = v < 0 ? 0 - cast(ulong) v : cast(ulong) v;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u);
    if (v < 0)
        buf[--i] = '-';
    return buf[i .. $];
}

@("parseLong")
unittest
{
    import std.exception : assertThrown;

    assert(parseLong("0") == 0);
    assert(parseLong("-0") == 0);
    assert(parseLong("42") == 42);
    assert(parseLong("-17") == -17);
    assert(parseLong("9223372036854775807") == long.max);
    assert(parseLong("-9223372036854775808") == long.min);
    assertThrown!NumberFormatException(parseLong("9223372036854775808"));
    assertThrown!NumberFormatException(parseLong("-9223372036854775809"));
    assertThrown!NumberFormatException(parseLong("99999999999999999999999"));
    assertThrown!NumberFormatException(parseLong(""));
    assertThrown!NumberFormatException(parseLong("-"));
    assertThrown!NumberFormatException(parseLong("1x"));
}

@("parseUlong")
unittest
{
    import std.exception : assertThrown;

    assert(parseUlong("0") == 0);
    assert(parseUlong("1000000000") == 1_000_000_000);
    assert(parseUlong("18446744073709551615") == ulong.max);
    assertThrown!NumberFormatException(parseUlong("18446744073709551616"));
    assertThrown!NumberFormatException(parseUlong("-1"));
    assertThrown!NumberFormatException(parseUlong(""));
}

@("formatLong")
unittest
{
    char[maxLongChars] b;
    assert(formatLong(b, 0) == "0");
    assert(formatLong(b, 7) == "7");
    assert(formatLong(b, -7) == "-7");
    assert(formatLong(b, long.max) == "9223372036854775807");
    assert(formatLong(b, long.min) == "-9223372036854775808");
}
