/// Number formatting and parsing helpers (exact `%.*f` style float printing, integer radix printing).
module langvm.numfmt;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import core.stdc.math : isnan, isinf, signbit;

/// `showFloatAt` of the language specification (section 14.3); `digits` must be in 0..17.
string formatFloatAt(double x, int digits)
{
    if (x != x)
        return "nan";
    if (x == double.infinity)
        return "inf";
    if (x == -double.infinity)
        return "-inf";
    char[512] buf = void;
    int n = snprintf(buf.ptr, buf.length, "%.*f", digits, x);
    return buf[0 .. n].idup;
}

/// Formats a signed integer in the given radix (2..36); lowercase digits, `-` for negatives.
string formatIntRadix(long x, int radix)
{
    immutable digitsStr = "0123456789abcdefghijklmnopqrstuvwxyz";
    ulong mag = x < 0 ? 0UL - cast(ulong) x : cast(ulong) x;
    char[72] tmp = void;
    size_t i = tmp.length;
    if (mag == 0)
        tmp[--i] = '0';
    while (mag != 0)
    {
        tmp[--i] = digitsStr[cast(size_t)(mag % radix)];
        mag /= radix;
    }
    if (x < 0)
        tmp[--i] = '-';
    return tmp[i .. $].idup;
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

/// Parses an integer in `radix`: optional sign, at least one digit, fits in 64 bits.
bool parseIntRadix(const(dchar)[] s, int radix, out long result)
{
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && (s[0] == '+' || s[0] == '-'))
    {
        neg = s[0] == '-';
        i = 1;
    }
    if (i >= s.length)
        return false;
    ulong v = 0;
    ulong limit = neg ? (1UL << 63) : ulong(long.max);
    for (; i < s.length; i++)
    {
        int d = digitValue(s[i]);
        if (d >= radix)
            return false;
        if (v > (limit - d) / radix)
            return false;
        v = v * radix + d;
    }
    result = neg ? cast(long)(0UL - v) : cast(long) v;
    return true;
}

/// Parses a float per the grammar of `parseFloat`; false when the text is not accepted.
bool parseFloatText(const(dchar)[] s, out double result)
{
    size_t i = 0;
    size_t n = s.length;
    char[] buf;
    if (i < n && (s[i] == '+' || s[i] == '-'))
    {
        buf ~= cast(char) s[i];
        i++;
    }
    size_t intDigits = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9')
    {
        buf ~= cast(char) s[i++];
        intDigits++;
    }
    size_t fracDigits = 0;
    if (i < n && s[i] == '.')
    {
        buf ~= '.';
        i++;
        while (i < n && s[i] >= '0' && s[i] <= '9')
        {
            buf ~= cast(char) s[i++];
            fracDigits++;
        }
        if (intDigits == 0 && fracDigits == 0)
            return false;
    }
    else if (intDigits == 0)
        return false;
    if (i < n && (s[i] == 'e' || s[i] == 'E'))
    {
        buf ~= 'e';
        i++;
        if (i < n && (s[i] == '+' || s[i] == '-'))
            buf ~= cast(char) s[i++];
        size_t ed = 0;
        while (i < n && s[i] >= '0' && s[i] <= '9')
        {
            buf ~= cast(char) s[i++];
            ed++;
        }
        if (ed == 0)
            return false;
    }
    if (i != n)
        return false;
    buf ~= '\0';
    result = strtod(buf.ptr, null);
    return true;
}
