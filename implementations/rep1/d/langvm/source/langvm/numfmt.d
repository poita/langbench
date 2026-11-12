/// Number formatting and parsing (SPEC.md sections 14.3, 15.2, 15.3).
module langvm.numfmt;

import std.bigint : BigInt;

/// `showFloatAt(x, d)` for `d` in 0..17: exactly what a correct `printf("%.*f")`
/// prints, computed with exact integer arithmetic.
string formatFixed(double x, int d)
{
    import std.math : isNaN, isInfinity, signbit;

    if (isNaN(x))
        return "nan";
    if (isInfinity(x))
        return x > 0 ? "inf" : "-inf";
    const neg = signbit(x) != 0;
    const bits = *cast(ulong*)&x;
    const expBits = cast(int)((bits >> 52) & 0x7ff);
    const frac = bits & ((1UL << 52) - 1);
    ulong m;
    int e;
    if (expBits == 0)
    {
        m = frac;
        e = -1074;
    }
    else
    {
        m = frac | (1UL << 52);
        e = expBits - 1075;
    }
    // |x| = m * 2^e; N = round_half_even(m * 2^e * 10^d)
    BigInt num = BigInt(m) * (BigInt(10) ^^ d);
    BigInt n;
    if (e >= 0)
        n = num << e;
    else
    {
        const sh = -e;
        BigInt q = num >> sh;
        BigInt r = num - (q << sh);
        BigInt half = BigInt(1) << (sh - 1);
        if (r > half || (r == half && (q % 2) == 1))
            q += 1;
        n = q;
    }
    import std.conv : to;

    string digits = n.to!string;
    while (digits.length < cast(size_t) d + 1)
        digits = "0" ~ digits;
    if (d > 0)
        digits = digits[0 .. $ - d] ~ "." ~ digits[$ - d .. $];
    return (neg ? "-" : "") ~ digits;
}

/// Digit characters for radices up to 36.
private immutable digitChars = "0123456789abcdefghijklmnopqrstuvwxyz";

/// The integer in the given radix (2..36); the magnitude is taken as unsigned.
string formatRadix(long x, int radix)
{
    ulong mag = x < 0 ? -cast(ulong) x : cast(ulong) x;
    if (mag == 0)
        return "0";
    char[65] buf;
    size_t p = buf.length;
    while (mag > 0)
    {
        buf[--p] = digitChars[cast(size_t)(mag % radix)];
        mag /= radix;
    }
    if (x < 0)
        buf[--p] = '-';
    return buf[p .. $].idup;
}

private int digitValue(dchar c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 10;
    return 99;
}

/// Parse `[+-]digits` in `radix`; false if malformed or out of range.
bool parseRadix(const(dchar)[] s, int radix, out long value)
{
    size_t i = 0;
    bool neg = false;
    if (s.length && (s[0] == '+' || s[0] == '-'))
    {
        neg = s[0] == '-';
        i = 1;
    }
    if (i >= s.length)
        return false;
    ulong mag = 0;
    const limit = neg ? (1UL << 63) : cast(ulong) long.max;
    for (; i < s.length; i++)
    {
        const d = digitValue(s[i]);
        if (d >= radix)
            return false;
        if (mag > (limit - d) / radix)
            return false;
        mag = mag * radix + d;
    }
    value = neg ? cast(long)(-mag) : cast(long) mag;
    return true;
}

/// Parse a float per SPEC.md 15.3; false if the text does not match the grammar.
bool parseFloatText(const(dchar)[] s, out double value)
{
    import core.stdc.stdlib : strtod;

    size_t i = 0;
    char[] buf;
    if (i < s.length && (s[i] == '+' || s[i] == '-'))
        buf ~= cast(char) s[i++];
    size_t intDigits = 0, fracDigits = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        buf ~= cast(char) s[i++];
        intDigits++;
    }
    if (i < s.length && s[i] == '.')
    {
        buf ~= '.';
        i++;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            buf ~= cast(char) s[i++];
            fracDigits++;
        }
    }
    if (intDigits == 0 && fracDigits == 0)
        return false;
    if (intDigits == 0 && buf.length && buf[$ - 1] == '.' && fracDigits == 0)
        return false;
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        buf ~= 'e';
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-'))
            buf ~= cast(char) s[i++];
        size_t ed = 0;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            buf ~= cast(char) s[i++];
            ed++;
        }
        if (ed == 0)
            return false;
    }
    if (i != s.length)
        return false;
    buf ~= '\0';
    value = strtod(buf.ptr, null);
    return true;
}

unittest
{
    assert(formatFixed(1.0, 6) == "1.000000");
    assert(formatFixed(0.1, 6) == "0.100000");
    assert(formatFixed(2.0 / 3.0, 6) == "0.666667");
    assert(formatFixed(-0.0, 6) == "-0.000000");
    assert(formatFixed(2.5, 0) == "2");
    assert(formatFixed(3.5, 0) == "4");
    assert(formatFixed(0.5, 0) == "0");
    assert(formatFixed(0.1 + 0.2, 17) == "0.30000000000000004");
    assert(formatFixed(1e21, 2) == "1000000000000000000000.00");
    assert(formatFixed(2.675, 2) == "2.67");
    assert(formatFixed(double.nan, 3) == "nan");
    assert(formatFixed(-double.infinity, 3) == "-inf");
    assert(formatFixed(double.min_normal * double.epsilon, 17) == "0.00000000000000000");
}

unittest
{
    assert(formatRadix(255, 16) == "ff");
    assert(formatRadix(-255, 2) == "-11111111");
    assert(formatRadix(long.min, 16) == "-8000000000000000");
    long v;
    assert(parseRadix("-0042", 10, v) && v == -42);
    assert(parseRadix("9223372036854775807", 10, v) && v == long.max);
    assert(!parseRadix("9223372036854775808", 10, v));
    assert(parseRadix("-9223372036854775808", 10, v) && v == long.min);
    assert(!parseRadix("", 10, v) && !parseRadix("+", 10, v) && !parseRadix("1_0", 10, v));
    assert(parseRadix("Zz", 36, v) && v == 35 * 36 + 35);
}

unittest
{
    double v;
    assert(parseFloatText("12.", v) && v == 12.0);
    assert(parseFloatText(".5", v) && v == 0.5);
    assert(parseFloatText("-1e3", v) && v == -1000.0);
    assert(!parseFloatText(".", v) && !parseFloatText("1e", v) && !parseFloatText("inf", v));
    assert(!parseFloatText(" 1", v) && !parseFloatText("1_0", v) && !parseFloatText("", v));
}
