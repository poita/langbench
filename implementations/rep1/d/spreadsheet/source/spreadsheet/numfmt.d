/// Conversion between doubles and their textual forms.
module spreadsheet.numfmt;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;

/// Numbers below this magnitude that are integral print as plain integers.
private enum double integerLimit = 1e15;

/**
 * Append the display form of `v` to `sink`.
 *
 * Zero prints as `0`; integral values with magnitude below 1e15 print as
 * decimal integers; everything else prints as C's `%.10g` (ten significant
 * digits, correctly rounded, ties to even).
 */
void formatNumber(Sink)(double v, ref Sink sink)
{
    char[40] buf = void;
    size_t n;
    if (v == 0)
    {
        buf[0] = '0';
        n = 1;
    }
    else if (v > -integerLimit && v < integerLimit && v == cast(double)cast(long) v)
    {
        long i = cast(long) v;
        bool neg = i < 0;
        ulong u = neg ? -cast(ulong) i : cast(ulong) i;
        size_t p = buf.length;
        while (u != 0)
        {
            buf[--p] = cast(char)('0' + u % 10);
            u /= 10;
        }
        if (neg)
            buf[--p] = '-';
        sink.put(buf[p .. $]);
        return;
    }
    else
    {
        // The C library rounds the exact binary value correctly.
        n = snprintf(buf.ptr, buf.length, "%.10g", v);
    }
    sink.put(buf[0 .. n]);
}

/// The display form of `v` as a string.
string formatNumber(double v) @safe
{
    import std.array : appender;
    auto app = appender!string();
    () @trusted { formatNumber(v, app); }();
    return app.data;
}

/**
 * Convert a decimal literal (`-?[0-9]+(\.[0-9]+)?`) to the nearest double
 * (ties to even).  Returns false if `s` is not such a literal.
 */
bool parseNumber(const(char)[] s, out double result) @trusted nothrow
{
    size_t i = 0;
    if (i < s.length && s[i] == '-')
        i++;
    size_t intStart = i;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
        i++;
    if (i == intStart)
        return false;
    if (i < s.length && s[i] == '.')
    {
        i++;
        size_t fracStart = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (i == fracStart)
            return false;
    }
    if (i != s.length)
        return false;

    char[64] small = void;
    if (s.length < small.length)
    {
        small[0 .. s.length] = s[];
        small[s.length] = 0;
        result = strtod(small.ptr, null);
        return true;
    }
    // Pathologically long literal: fall back to a heap copy.
    auto heap = new char[s.length + 1];
    heap[0 .. s.length] = s[];
    heap[s.length] = 0;
    result = strtod(heap.ptr, null);
    return true;
}
