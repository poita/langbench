/// Formatting of doubles as the shortest string that reads back exactly.
module jinjalite.floatfmt;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.array : appender;

/++
    Format `x` the way Python's `repr(float)` does: the shortest digit string that
    converts back to `x`, in positional notation for decimal exponents in
    `[-4, 16)` and in scientific notation (`1e+16`, `1.5e-05`) otherwise.
+/
string formatFloat(double x)
{
    if (x != x)
        return "nan";
    if (x == double.infinity)
        return "inf";
    if (x == -double.infinity)
        return "-inf";
    const negative = (x < 0) || (x == 0 && 1.0 / x < 0);
    if (x == 0)
        return negative ? "-0.0" : "0.0";

    char[48] buf = void;
    // The nearest p-digit decimal is correctly rounded by printf; the first
    // precision whose result reads back exactly is the shortest representation.
    foreach (precision; 1 .. 18)
    {
        const n = snprintf(buf.ptr, buf.length, "%.*e", precision - 1, x < 0 ? -x : x);
        buf[n] = '\0';
        if (precision == 17 || strtod(buf.ptr, null) == (x < 0 ? -x : x))
            return layout(negative, buf[0 .. n]);
    }
    assert(0);
}

/// Re-lay out the output of printf's `%e` (`d.ddde+XX`) following Python's rules.
private string layout(bool negative, const(char)[] sci)
{
    char[20] digits = void;
    size_t nd = 0;
    size_t i = 0;
    for (; i < sci.length && sci[i] != 'e'; ++i)
        if (sci[i] != '.')
            digits[nd++] = sci[i];
    // Parse the exponent after 'e'.
    ++i;
    bool expNeg = false;
    if (sci[i] == '-') { expNeg = true; ++i; }
    else if (sci[i] == '+') ++i;
    int e = 0;
    for (; i < sci.length; ++i)
        e = e * 10 + (sci[i] - '0');
    if (expNeg)
        e = -e;
    while (nd > 1 && digits[nd - 1] == '0')
        --nd;

    auto o = appender!string();
    if (negative)
        o.put('-');
    if (e >= -4 && e < 16)
    {
        if (e >= 0)
        {
            const intLen = cast(size_t) e + 1;
            foreach (k; 0 .. intLen)
                o.put(k < nd ? digits[k] : '0');
            o.put('.');
            if (nd > intLen)
                o.put(digits[intLen .. nd]);
            else
                o.put('0');
        }
        else
        {
            o.put("0.");
            foreach (_; 0 .. -e - 1)
                o.put('0');
            o.put(digits[0 .. nd]);
        }
    }
    else
    {
        o.put(digits[0]);
        if (nd > 1)
        {
            o.put('.');
            o.put(digits[1 .. nd]);
        }
        o.put('e');
        o.put(e < 0 ? '-' : '+');
        const ae = e < 0 ? -e : e;
        if (ae < 10)
            o.put('0');
        import std.conv : to;
        o.put(ae.to!string);
    }
    return o.data;
}

unittest
{
    assert(formatFloat(3.0) == "3.0");
    assert(formatFloat(0.5) == "0.5");
    assert(formatFloat(-2.5) == "-2.5");
    assert(formatFloat(0.0) == "0.0");
    assert(formatFloat(-0.0) == "-0.0");
    assert(formatFloat(1e15) == "1000000000000000.0");
    assert(formatFloat(1e16) == "1e+16");
    assert(formatFloat(0.0001) == "0.0001");
    assert(formatFloat(0.00001) == "1e-05");
    assert(formatFloat(0.1 + 0.2) == "0.30000000000000004");
    assert(formatFloat(1.5e300) == "1.5e+300");
    assert(formatFloat(123456789.125) == "123456789.125");
    assert(formatFloat(1.0 / 3) == "0.3333333333333333");
    assert(formatFloat(double.min_normal * double.epsilon) == "5e-324");
    assert(formatFloat(1.7976931348623157e308) == "1.7976931348623157e+308");
    assert(formatFloat(12345678901234567.0) == "1.2345678901234568e+16");
}
