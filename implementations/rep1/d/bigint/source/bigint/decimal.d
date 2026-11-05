/**
 * Linear-time conversion between decimal text and base-10^9 magnitudes.
 */
module bigint.decimal;

import bigint.magnitude : BASE, DIGITS_PER_LIMB, trimmed;

/// Result of parsing a decimal token.
struct Parsed
{
    /// True iff the token had a `-` and the value is non-zero.
    bool negative;
    /// Normalised little-endian magnitude (empty for zero).
    uint[] magnitude;
}

/**
 * Parses `-?[0-9]+` (leading zeros and `-0` allowed). Digits are consumed nine
 * at a time from the right. Input is assumed well formed.
 */
Parsed parseDecimal(scope const(char)[] token) pure nothrow @safe
{
    bool neg = false;
    if (token.length && token[0] == '-')
    {
        neg = true;
        token = token[1 .. $];
    }
    size_t lead = 0;
    while (lead < token.length && token[lead] == '0')
        ++lead;
    token = token[lead .. $];
    if (token.length == 0)
        return Parsed(false, null);

    auto mag = new uint[(token.length + DIGITS_PER_LIMB - 1) / DIGITS_PER_LIMB];
    size_t end = token.length;
    foreach (i; 0 .. mag.length)
    {
        immutable size_t start = end >= DIGITS_PER_LIMB ? end - DIGITS_PER_LIMB : 0;
        uint limb = 0;
        foreach (k; start .. end)
            limb = limb * 10 + (token[k] - '0');
        mag[i] = limb;
        end = start;
    }
    return Parsed(neg, trimmed(mag));
}

/// Number of characters `formatDecimal` appends for the given value.
size_t decimalLength(bool negative, scope const(uint)[] mag) pure nothrow @nogc @safe
{
    if (mag.length == 0)
        return 1;
    uint top = mag[$ - 1];
    size_t digits = 1;
    while (top >= 10)
    {
        top /= 10;
        ++digits;
    }
    return (negative ? 1 : 0) + digits + (mag.length - 1) * DIGITS_PER_LIMB;
}

/**
 * Writes the canonical decimal form into `dst`, which must be at least
 * `decimalLength` characters long. Returns the number of characters written.
 */
size_t formatDecimal(char[] dst, bool negative, scope const(uint)[] mag) pure nothrow @nogc @safe
{
    if (mag.length == 0)
    {
        dst[0] = '0';
        return 1;
    }
    size_t pos = 0;
    if (negative)
        dst[pos++] = '-';
    // Top limb without padding.
    {
        char[10] tmp = void;
        size_t k = tmp.length;
        uint v = mag[$ - 1];
        do
        {
            tmp[--k] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        foreach (c; tmp[k .. $])
            dst[pos++] = c;
    }
    for (size_t i = mag.length - 1; i-- > 0;)
    {
        uint v = mag[i];
        foreach_reverse (k; 0 .. DIGITS_PER_LIMB)
        {
            dst[pos + k] = cast(char)('0' + v % 10);
            v /= 10;
        }
        pos += DIGITS_PER_LIMB;
    }
    return pos;
}

/// Convenience: canonical decimal string of a value.
string toDecimal(bool negative, scope const(uint)[] mag) pure nothrow @safe
{
    auto buf = new char[decimalLength(negative, mag)];
    immutable n = formatDecimal(buf, negative, mag);
    assert(n == buf.length);
    return (() @trusted => cast(string) buf)();
}
