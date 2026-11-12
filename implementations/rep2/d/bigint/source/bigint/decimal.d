/**
 * Conversion between decimal text and the base-10^9 limb representation.
 *
 * Both directions are linear in the number of digits: each limb corresponds
 * to exactly nine decimal digits.
 */
module bigint.decimal;

import bigint.natural : Natural, limbBase, limbDigits, normalized;

/// Thrown for text that is not a valid decimal integer.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Parses a run of ASCII digits (no sign) into a normalised natural number.
 * Leading zeros are accepted and ignored.
 *
 * Throws: $(LREF ParseException) if `digits` is empty or contains a
 * non-digit.
 */
Natural parseDigits(const(char)[] digits) pure @safe
{
    if (digits.length == 0)
        throw new ParseException("expected at least one digit");
    foreach (c; digits)
        if (c < '0' || c > '9')
            throw new ParseException("invalid digit in integer literal");

    size_t start = 0;
    while (start < digits.length && digits[start] == '0')
        ++start;
    digits = digits[start .. $];

    auto limbs = new uint[(digits.length + limbDigits - 1) / limbDigits];
    size_t end = digits.length;
    foreach (ref limb; limbs)
    {
        immutable begin = end > limbDigits ? end - limbDigits : 0;
        uint v = 0;
        foreach (c; digits[begin .. end])
            v = v * 10 + (c - '0');
        limb = v;
        end = begin;
    }
    return limbs;
}

/// Number of decimal digits of a normalised natural number (zero has one digit).
size_t digitCount(const(uint)[] a) pure nothrow @nogc @safe
{
    if (a.length == 0)
        return 1;
    size_t n = (a.length - 1) * limbDigits;
    uint top = a[$ - 1];
    while (top != 0)
    {
        ++n;
        top /= 10;
    }
    return n;
}

/**
 * Appends the decimal digits of a normalised natural number to `buf`
 * (no sign, no leading zeros; zero is "0") and returns the extended buffer.
 */
char[] appendDigits(char[] buf, const(uint)[] a) pure nothrow @safe
{
    if (a.length == 0)
    {
        buf ~= '0';
        return buf;
    }
    buf.reserve(buf.length + digitCount(a));
    char[limbDigits] tmp;

    // Most significant limb: no zero padding.
    uint top = a[$ - 1];
    size_t pos = limbDigits;
    while (top != 0)
    {
        tmp[--pos] = cast(char)('0' + top % 10);
        top /= 10;
    }
    buf ~= tmp[pos .. $];

    foreach_reverse (limb; a[0 .. $ - 1])
    {
        uint v = limb;
        foreach_reverse (k; 0 .. limbDigits)
        {
            tmp[k] = cast(char)('0' + v % 10);
            v /= 10;
        }
        buf ~= tmp[];
    }
    return buf;
}

@("decimal: parse strips leading zeros")
unittest
{
    assert(parseDigits("0").length == 0);
    assert(parseDigits("0000").length == 0);
    assert(parseDigits("007") == [7u]);
    assert(parseDigits("1000000000") == [0u, 1u]);
    assert(parseDigits("123456789012345678") == [12_345_678u, 123_456_789u]);
}

@("decimal: parse rejects malformed input")
unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(parseDigits(""));
    assertThrown!ParseException(parseDigits("12a"));
    assertThrown!ParseException(parseDigits("-1"));
}

@("decimal: print pads inner limbs")
unittest
{
    assert(appendDigits(null, null) == "0");
    assert(appendDigits(null, [1u, 2u]) == "2000000001");
    assert(appendDigits(null, [0u, 0u, 5u]) == "5000000000000000000");
    assert(appendDigits("-".dup, [42u]) == "-42");
    assert(digitCount(null) == 1);
    assert(digitCount([0u, 1u]) == 10);
    assert(digitCount([999_999_999u]) == 9);
}

@("decimal: round trip of a long number")
unittest
{
    string s = "9876543210123456789098765432101234567890987654321";
    assert(appendDigits(null, parseDigits(s)) == s);
}
