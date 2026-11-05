/// Float text conversion: strtod in, `%.16e` out.
module toml.floatfmt;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;

/**
 * Formats a double the way TOML decode output requires: `nan`, `inf`, `-inf`,
 * or exactly 17 significant digits in scientific notation (`%.16e`).
 */
string formatFloat(double v)
{
    import core.stdc.math : isnan, isinf;

    if (isnan(v))
        return "nan";
    if (isinf(v))
        return v < 0 ? "-inf" : "inf";
    char[40] buf = void;
    immutable n = snprintf(buf.ptr, buf.length, "%.16e", v);
    assert(n > 0 && n < buf.length);
    return buf[0 .. n].idup;
}

/// Parses a decimal float literal (no underscores) with correct rounding.
/// Overflow yields infinity and underflow zero, as `strtod` does.
double parseFloatDecimal(scope const(char)[] s)
{
    // strtod needs a terminating NUL.
    char[128] small = void;
    if (s.length < small.length)
    {
        small[0 .. s.length] = s;
        small[s.length] = 0;
        return strtod(small.ptr, null);
    }
    auto big = new char[s.length + 1];
    big[0 .. s.length] = s;
    big[s.length] = 0;
    return strtod(big.ptr, null);
}

/// Parses canonical float text (`nan`, `inf`, `-inf`, or decimal).
double parseFloatText(scope const(char)[] s)
{
    switch (s)
    {
    case "nan":
        return double.nan;
    case "inf":
        return double.infinity;
    case "-inf":
        return -double.infinity;
    default:
        return parseFloatDecimal(s);
    }
}
