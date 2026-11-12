/**
 * Integer and float literals: validation, conversion and canonical text.
 */
module toml.number;

import toml.value : Kind;

private bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }

private int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decimal text of a sign and magnitude (handles `long.min`).
string formatInteger(bool negative, ulong magnitude) @safe pure
{
    char[24] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude != 0);
    if (negative && !(i == buf.length - 1 && buf[i] == '0'))
        buf[--i] = '-';
    return buf[i .. $].idup;
}

/// The canonical text of a double: `nan`, `inf`, `-inf`, or `%.16e` (17 significant digits).
string formatFloat(double v) @trusted
{
    import core.stdc.stdio : snprintf;
    import core.stdc.math : isnan, isinf;

    if (isnan(v)) return "nan";
    if (isinf(v)) return v < 0 ? "-inf" : "inf";
    char[64] buf;
    immutable n = snprintf(buf.ptr, buf.length, "%.16e", v);
    assert(n > 0 && n < buf.length);
    return buf[0 .. n].idup;
}

/**
 * Advances `i` over a run of decimal digits with single underscores between digits.
 * When `noLeadingZero` is set, a leading `0` may not be followed by another digit.
 * Returns false if there is no digit at `i` or an underscore/zero rule is broken.
 */
private bool scanDigits(const(char)[] s, ref size_t i, bool noLeadingZero) @safe pure nothrow @nogc
{
    immutable n = s.length;
    if (i >= n || !isDigit(s[i]))
        return false;
    if (noLeadingZero && s[i] == '0')
    {
        ++i;
        return !(i < n && (isDigit(s[i]) || s[i] == '_'));
    }
    ++i;
    while (i < n)
    {
        if (isDigit(s[i]))
            ++i;
        else if (s[i] == '_' && i + 1 < n && isDigit(s[i + 1]))
            i += 2;
        else
            break;
    }
    return true;
}

private bool parseRadix(const(char)[] s, uint radix, out string text) @safe pure
{
    // s excludes the two-character prefix.
    if (s.length == 0)
        return false;
    ulong value = 0;
    bool prevDigit = false;
    foreach (idx, c; s)
    {
        if (c == '_')
        {
            if (!prevDigit || idx + 1 == s.length)
                return false;
            prevDigit = false;
            continue;
        }
        immutable d = hexValue(c);
        if (d < 0 || d >= radix)
            return false;
        if (value > (long.max - d) / radix)
            return false;
        value = value * radix + d;
        prevDigit = true;
    }
    text = formatInteger(false, value);
    return true;
}

private bool parseDecimalInteger(const(char)[] s, bool negative, out string text) @safe pure
{
    ulong value = 0;
    immutable limit = negative ? cast(ulong) long.max + 1 : cast(ulong) long.max;
    foreach (c; s)
    {
        if (c == '_')
            continue;
        immutable d = c - '0';
        if (value > (limit - d) / 10)
            return false;
        value = value * 10 + d;
    }
    text = formatInteger(negative, value);
    return true;
}

private double toDouble(const(char)[] s) @trusted
{
    import core.stdc.stdlib : strtod;

    auto buf = new char[s.length + 1];
    size_t n = 0;
    foreach (c; s)
        if (c != '_')
            buf[n++] = c;
    buf[n] = '\0';
    return strtod(buf.ptr, null);
}

/**
 * Parses an integer or float literal.
 *
 * `token` is the complete literal as written. On success returns true and sets
 * `kind` (`Kind.integer` or `Kind.floating`) and the canonical `text`.
 * Returns false if `token` is not a valid TOML number or does not fit.
 */
bool parseNumber(const(char)[] token, out Kind kind, out string text) @safe
{
    if (token.length == 0)
        return false;

    // Prefixed integers: never signed, prefix in lower case.
    if (token.length >= 2 && token[0] == '0' && (token[1] == 'x' || token[1] == 'o' || token[1] == 'b'))
    {
        kind = Kind.integer;
        immutable radix = token[1] == 'x' ? 16u : token[1] == 'o' ? 8u : 2u;
        return parseRadix(token[2 .. $], radix, text);
    }

    size_t i = 0;
    bool negative = false;
    if (token[0] == '+' || token[0] == '-')
    {
        negative = token[0] == '-';
        i = 1;
    }
    const rest = token[i .. $];
    if (rest == "inf")
    {
        kind = Kind.floating;
        text = negative ? "-inf" : "inf";
        return true;
    }
    if (rest == "nan")
    {
        kind = Kind.floating;
        text = "nan";
        return true;
    }

    immutable intStart = i;
    if (!scanDigits(token, i, true))
        return false;
    immutable intEnd = i;
    if (i == token.length)
    {
        kind = Kind.integer;
        return parseDecimalInteger(token[intStart .. intEnd], negative, text);
    }

    if (token[i] == '.')
    {
        ++i;
        if (!scanDigits(token, i, false))
            return false;
    }
    if (i < token.length && (token[i] == 'e' || token[i] == 'E'))
    {
        ++i;
        if (i < token.length && (token[i] == '+' || token[i] == '-'))
            ++i;
        if (!scanDigits(token, i, false))
            return false;
    }
    if (i != token.length)
        return false;
    kind = Kind.floating;
    text = formatFloat(toDouble(token));
    return true;
}

unittest
{
    Kind k;
    string t;
    void ok(string tok, Kind ek, string et)
    {
        assert(parseNumber(tok, k, t), tok);
        assert(k == ek && t == et, tok ~ " -> " ~ t);
    }
    void bad(string tok) { assert(!parseNumber(tok, k, t), tok); }

    ok("0", Kind.integer, "0");
    ok("+0", Kind.integer, "0");
    ok("-0", Kind.integer, "0");
    ok("-17", Kind.integer, "-17");
    ok("1_000", Kind.integer, "1000");
    ok("0xDEAD_beef", Kind.integer, "3735928559");
    ok("0o755", Kind.integer, "493");
    ok("0b1101", Kind.integer, "13");
    ok("9223372036854775807", Kind.integer, "9223372036854775807");
    ok("-9223372036854775808", Kind.integer, "-9223372036854775808");
    ok("0x7FFFFFFFFFFFFFFF", Kind.integer, "9223372036854775807");
    ok("1.0", Kind.floating, "1.0000000000000000e+00");
    ok("3.1415", Kind.floating, "3.1415000000000002e+00");
    ok("-0.0", Kind.floating, "-0.0000000000000000e+00");
    ok("0e0", Kind.floating, "0.0000000000000000e+00");
    ok("0e00", Kind.floating, "0.0000000000000000e+00");
    ok("1e308", Kind.floating, "1.0000000000000000e+308");
    ok("5e-324", Kind.floating, "4.9406564584124654e-324");
    ok("6.626e-34", Kind.floating, "6.6259999999999998e-34");
    ok("1e999", Kind.floating, "inf");
    ok("-1e999", Kind.floating, "-inf");
    ok("1E+2_0", Kind.floating, "1.0000000000000000e+20");
    ok("-nan", Kind.floating, "nan");
    ok("+inf", Kind.floating, "inf");
    ok("-inf", Kind.floating, "-inf");

    foreach (b; ["", "+", "01", "+01", "1__0", "_1", "1_", "0X1", "-0x1", "0x", "0x_1", "0xg",
                 "0o8", "0b2", "9223372036854775808", "-9223372036854775809",
                 "0xFFFFFFFFFFFFFFFF", ".5", "5.", "1.e2", "1e", "01.5", "1._5", "1.5_",
                 "Inf", "NaN", "infx", "1e+", "--1", "1.2.3", "0_1"])
        bad(b);
}
