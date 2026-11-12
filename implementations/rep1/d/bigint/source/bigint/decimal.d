/**
 * Conversion between decimal text and base-10^9 magnitudes.
 *
 * Because the limb radix is a power of ten, both directions are linear in the
 * number of digits.
 */
module bigint.decimal;

import bigint.exceptions : ParseException;
import bigint.magnitude : BASE, BASE_DIGITS, trim;

@safe pure
{

/**
 * Parses a string of ASCII digits (no sign) into a normalised magnitude.
 * Leading zeros are accepted. Throws `ParseException` for an empty string or a
 * non-digit character.
 */
uint[] parseDigits(scope const(char)[] digits)
{
    if (digits.length == 0)
        throw new ParseException("no digits");
    foreach (c; digits)
        if (c < '0' || c > '9')
            throw new ParseException;

    size_t start = 0;
    while (start < digits.length && digits[start] == '0')
        ++start;
    digits = digits[start .. $];

    auto limbs = new uint[(digits.length + BASE_DIGITS - 1) / BASE_DIGITS];
    size_t end = digits.length;
    foreach (ref limb; limbs)
    {
        const begin = end >= BASE_DIGITS ? end - BASE_DIGITS : 0;
        uint v = 0;
        foreach (c; digits[begin .. end])
            v = v * 10 + (c - '0');
        limb = v;
        end = begin;
    }
    return limbs;
}

/// Number of decimal digits needed to print `mag` (zero needs one digit).
size_t digitCount(scope const(uint)[] mag) nothrow @nogc
{
    if (mag.length == 0)
        return 1;
    size_t n = 1;
    for (uint top = mag[$ - 1]; top >= 10; top /= 10)
        ++n;
    return n + (mag.length - 1) * BASE_DIGITS;
}

/// Formats a magnitude as decimal digits without leading zeros ("0" for zero).
char[] formatDigits(scope const(uint)[] mag) nothrow
{
    auto buf = new char[digitCount(mag)];
    if (mag.length == 0)
    {
        buf[0] = '0';
        return buf;
    }
    size_t pos = buf.length;
    foreach (i, limb; mag)
    {
        uint v = limb;
        if (i + 1 == mag.length)
        {
            do
            {
                buf[--pos] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v != 0);
        }
        else
        {
            foreach (_; 0 .. BASE_DIGITS)
            {
                buf[--pos] = cast(char)('0' + v % 10);
                v /= 10;
            }
        }
    }
    assert(pos == 0);
    return buf;
}

} // @safe pure

unittest
{
    assert(parseDigits("0").length == 0);
    assert(parseDigits("000").length == 0);
    assert(parseDigits("0007") == [7u]);
    assert(parseDigits("1000000000") == [0u, 1]);
    assert(parseDigits("999999999999999999") == [BASE - 1, BASE - 1]);
    assert(formatDigits(null) == "0");
    assert(formatDigits([0u, 1]) == "1000000000");
    assert(formatDigits([5u, 7]) == "7000000005");
    assert(digitCount([0u, 0, 12]) == 20);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(parseDigits(""));
    assertThrown!ParseException(parseDigits("12a"));
    assertThrown!ParseException(parseDigits("-1"));
}

unittest
{
    // round trip on a 1000-digit number
    char[] s;
    foreach (i; 0 .. 1000)
        s ~= cast(char)('1' + i % 9);
    assert(formatDigits(parseDigits(s)) == s);
}
