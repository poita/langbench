/// Number parsing and formatting.
module jq.number;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import core.stdc.math : fabs;
import jq.buffer;

private immutable double[23] pow10tab = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
    1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

/// Check that `s` is exactly one JSON number (RFC 8259 grammar).
bool isJsonNumber(const(char)[] s) pure nothrow @nogc @safe
{
    size_t i = 0;
    immutable n = s.length;
    if (i < n && s[i] == '-')
        ++i;
    if (i >= n)
        return false;
    if (s[i] == '0')
        ++i;
    else if (s[i] >= '1' && s[i] <= '9')
        while (i < n && s[i] >= '0' && s[i] <= '9')
            ++i;
    else
        return false;
    if (i < n && s[i] == '.')
    {
        ++i;
        immutable st = i;
        while (i < n && s[i] >= '0' && s[i] <= '9')
            ++i;
        if (i == st)
            return false;
    }
    if (i < n && (s[i] == 'e' || s[i] == 'E'))
    {
        ++i;
        if (i < n && (s[i] == '+' || s[i] == '-'))
            ++i;
        immutable st = i;
        while (i < n && s[i] >= '0' && s[i] <= '9')
            ++i;
        if (i == st)
            return false;
    }
    return i == n;
}

/// Convert the text of a syntactically valid number to the nearest double.
/// Plain integers and short decimals take an exact fast path; everything
/// else goes through `strtod`.
double parseNumber(const(char)[] s) nothrow @trusted
{
    size_t i = 0;
    immutable n = s.length;
    bool neg = false;
    if (i < n && s[i] == '-')
    {
        neg = true;
        ++i;
    }
    ulong mant = 0;
    int digits = 0, frac = 0;
    bool simple = true;
    size_t j = i;
    for (; j < n && s[j] >= '0' && s[j] <= '9'; ++j)
    {
        mant = mant * 10 + (s[j] - '0');
        ++digits;
    }
    if (j < n && s[j] == '.')
    {
        ++j;
        for (; j < n && s[j] >= '0' && s[j] <= '9'; ++j)
        {
            mant = mant * 10 + (s[j] - '0');
            ++digits;
            ++frac;
        }
    }
    if (j != n)
        simple = false; // exponent or junk
    if (simple && digits <= 15 && frac <= 22)
    {
        double d = cast(double) mant;
        if (frac)
            d /= pow10tab[frac];
        return neg ? -d : d;
    }
    char[64] stack = void;
    char[] tmp = n < 63 ? stack[] : new char[n + 1];
    tmp[0 .. n] = s[];
    tmp[n] = 0;
    return strtod(tmp.ptr, null);
}

/// Parse `s` as a JSON number; returns false if it is not one.
bool tryParseNumber(const(char)[] s, out double d) nothrow @trusted
{
    if (!isJsonNumber(s))
        return false;
    d = parseNumber(s);
    return true;
}

private void putLong(ref Buf b, long v) pure nothrow @trusted
{
    char[24] tmp = void;
    size_t p = tmp.length;
    ulong u = v < 0 ? -cast(ulong) v : cast(ulong) v;
    do
    {
        tmp[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u);
    if (v < 0)
        tmp[--p] = '-';
    b.put(tmp[p .. $]);
}

/// Append the output form of `d`: integers without decimal point, other
/// numbers in the shortest `%.15g`/`%.16g`/`%.17g` form that round-trips.
void putNumber(ref Buf b, double d) nothrow @trusted
{
    if (d != d)
    {
        b.put("null");
        return;
    }
    immutable a = fabs(d);
    if (a < 9_007_199_254_740_992.0)
    {
        immutable l = cast(long) d;
        if (cast(double) l == d)
        {
            putLong(b, l);
            return;
        }
    }
    else if (a > 1.7976931348623157e308)
    {
        b.put(d < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308");
        return;
    }
    char[40] tmp = void;
    int len = 0;
    foreach (prec; 15 .. 18)
    {
        len = snprintf(tmp.ptr, tmp.length, "%.*g", prec, d);
        if (prec == 17 || strtod(tmp.ptr, null) == d)
            break;
    }
    // strip trailing zeros of the fraction
    bool hasDot = false, hasExp = false;
    foreach (c; tmp[0 .. len])
    {
        if (c == '.')
            hasDot = true;
        else if (c == 'e')
            hasExp = true;
    }
    if (hasDot && !hasExp)
    {
        while (tmp[len - 1] == '0')
            --len;
        if (tmp[len - 1] == '.')
            --len;
    }
    b.put(tmp[0 .. len]);
}
