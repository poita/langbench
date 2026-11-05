/**
 * Scanners and formatters for TOML's non-string scalars: integers, floats and
 * the four date-time types. They are purely textual and ASCII-only.
 */
module toml.scalar;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.conv : to;
import toml.node;

private TomlException bad(string what) pure nothrow @safe
{
    return new TomlException(what);
}

/// True for an ASCII decimal digit.
bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }

private int hexVal(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Value of an ASCII hex digit, or -1.
int hexDigit(char c) pure nothrow @safe @nogc { return hexVal(c); }

/// Formats a double as 17 significant digits in scientific notation
/// (`%.16e`), or `nan`, `inf`, `-inf`.
string formatFloat(double x) @trusted
{
    if (x != x) return "nan";
    if (x == double.infinity) return "inf";
    if (x == -double.infinity) return "-inf";
    char[48] b = void;
    immutable n = snprintf(b.ptr, b.length, "%.16e", x);
    return b[0 .. n].idup;
}

/// Parses a bare number token (integer or float, any base, or inf/nan).
Node parseNumber(const(char)[] t)
{
    if (t.length == 0)
        throw bad("empty value");
    // special floats
    {
        const(char)[] u = t;
        bool neg = false;
        if (u[0] == '+' || u[0] == '-')
        {
            neg = u[0] == '-';
            u = u[1 .. $];
        }
        if (u == "inf")
            return Node.scalar(Kind.float_, neg ? "-inf" : "inf");
        if (u == "nan")
            return Node.scalar(Kind.float_, "nan");
    }
    if (t.length > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'o' || t[1] == 'b'))
        return parsePrefixed(t);

    size_t i = 0;
    bool neg = false;
    if (t[0] == '+' || t[0] == '-')
    {
        neg = t[0] == '-';
        i = 1;
    }
    immutable intStart = i;
    if (i >= t.length) throw bad("invalid number");
    if (t[i] == '0')
        ++i;
    else if (t[i] >= '1' && t[i] <= '9')
    {
        ++i;
        scanDigits(t, i);
    }
    else
        throw bad("invalid number");
    immutable intEnd = i;
    if (i == t.length)
    {
        // plain decimal integer
        ulong mag = 0;
        foreach (c; t[intStart .. intEnd])
        {
            if (c == '_') continue;
            immutable d = c - '0';
            if (mag > (ulong.max - d) / 10)
                throw bad("integer out of range");
            mag = mag * 10 + d;
        }
        return Node.scalar(Kind.integer, signedText(mag, neg));
    }

    // float
    char[] clean;
    clean.reserve(t.length + 1);
    if (neg) clean ~= '-';
    foreach (c; t[intStart .. intEnd])
        if (c != '_') clean ~= c;
    if (t[i] == '.')
    {
        clean ~= '.';
        ++i;
        immutable s = i;
        if (!scanFirstDigit(t, i)) throw bad("invalid float");
        foreach (c; t[s .. i])
            if (c != '_') clean ~= c;
    }
    if (i < t.length && (t[i] == 'e' || t[i] == 'E'))
    {
        clean ~= 'e';
        ++i;
        if (i < t.length && (t[i] == '+' || t[i] == '-'))
        {
            clean ~= t[i];
            ++i;
        }
        immutable s = i;
        if (!scanFirstDigit(t, i)) throw bad("invalid float");
        foreach (c; t[s .. i])
            if (c != '_') clean ~= c;
    }
    if (i != t.length)
        throw bad("invalid float");
    clean ~= '\0';
    immutable double v = (() @trusted => strtod(clean.ptr, null))();
    return Node.scalar(Kind.float_, formatFloat(v));
}

/// After a first digit has been consumed: consumes `(_? digit)*`.
private void scanDigits(const(char)[] t, ref size_t i) pure nothrow @safe @nogc
{
    while (i < t.length)
    {
        if (isDigit(t[i]))
            ++i;
        else if (t[i] == '_' && i + 1 < t.length && isDigit(t[i + 1]))
            i += 2;
        else
            break;
    }
}

/// Consumes `digit (_? digit)*`; false if there is no leading digit.
private bool scanFirstDigit(const(char)[] t, ref size_t i) pure nothrow @safe @nogc
{
    if (i >= t.length || !isDigit(t[i]))
        return false;
    ++i;
    scanDigits(t, i);
    return true;
}

private string signedText(ulong mag, bool neg) pure @safe
{
    if (neg)
    {
        if (mag > (cast(ulong) long.max) + 1)
            throw bad("integer out of range");
        if (mag == 0)
            return "0";
        if (mag == (cast(ulong) long.max) + 1)
            return "-9223372036854775808";
        return "-" ~ mag.to!string;
    }
    if (mag > long.max)
        throw bad("integer out of range");
    return mag.to!string;
}

private Node parsePrefixed(const(char)[] t)
{
    uint base;
    final switch (t[1])
    {
    case 'x': base = 16; break;
    case 'o': base = 8; break;
    case 'b': base = 2; break;
    }
    ulong mag = 0;
    bool prevDigit = false;
    foreach (i, c; t[2 .. $])
    {
        if (c == '_')
        {
            if (!prevDigit) throw bad("misplaced underscore");
            prevDigit = false;
            continue;
        }
        immutable d = hexVal(c);
        if (d < 0 || d >= base)
            throw bad("invalid digit");
        if (mag > (ulong.max - d) / base)
            throw bad("integer out of range");
        mag = mag * base + d;
        prevDigit = true;
    }
    if (!prevDigit)
        throw bad("trailing underscore");
    return Node.scalar(Kind.integer, signedText(mag, false));
}

// ---------------------------------------------------------------- date-times

private uint digitsAt(string s, size_t p, size_t n)
{
    if (p + n > s.length) throw bad("truncated date-time");
    uint v = 0;
    foreach (c; s[p .. p + n])
    {
        if (!isDigit(c)) throw bad("invalid date-time");
        v = v * 10 + (c - '0');
    }
    return v;
}

private bool isLeap(uint y) pure nothrow @safe @nogc
{
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

/// True if `s[p ..]` starts with `DDDD-`, the start of a date.
bool looksLikeDate(string s, size_t p) pure nothrow @safe @nogc
{
    return p + 4 < s.length && isDigit(s[p]) && isDigit(s[p + 1]) && isDigit(s[p + 2])
        && isDigit(s[p + 3]) && s[p + 4] == '-';
}

/// True if `s[p ..]` starts with `DD:`, the start of a time.
bool looksLikeTime(string s, size_t p) pure nothrow @safe @nogc
{
    return p + 2 < s.length && isDigit(s[p]) && isDigit(s[p + 1]) && s[p + 2] == ':';
}

/**
 * Parses a date, date-time or time starting at `p` (which must satisfy
 * $(LREF looksLikeDate) or $(LREF looksLikeTime)). Advances `p` past it.
 */
Node parseDateTime(string s, ref size_t p)
{
    string text;
    if (looksLikeTime(s, p))
    {
        text = parseTime(s, p);
        return Node.scalar(Kind.timeLocal, text);
    }
    immutable year = digitsAt(s, p, 4);
    if (s[p + 4] != '-' || p + 10 > s.length || s[p + 7] != '-')
        throw bad("invalid date");
    immutable mon = digitsAt(s, p + 5, 2);
    immutable day = digitsAt(s, p + 8, 2);
    static immutable ubyte[12] dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (year < 1) throw bad("invalid year");
    if (mon < 1 || mon > 12) throw bad("invalid month");
    immutable maxDay = (mon == 2 && isLeap(year)) ? 29 : dim[mon - 1];
    if (day < 1 || day > maxDay) throw bad("invalid day");
    string date = s[p .. p + 10];
    p += 10;
    bool hasTime = false;
    if (p < s.length)
    {
        immutable c = s[p];
        if (c == 'T' || c == 't')
            hasTime = true;
        else if (c == ' ' && looksLikeTime(s, p + 1))
            hasTime = true;
    }
    if (!hasTime)
        return Node.scalar(Kind.dateLocal, date);
    ++p;
    text = date ~ "T" ~ parseTime(s, p);
    if (p < s.length)
    {
        immutable c = s[p];
        if (c == 'Z' || c == 'z')
        {
            ++p;
            return Node.scalar(Kind.datetime, text ~ "Z");
        }
        if (c == '+' || c == '-')
        {
            immutable oh = digitsAt(s, p + 1, 2);
            if (p + 3 >= s.length || s[p + 3] != ':') throw bad("invalid offset");
            immutable om = digitsAt(s, p + 4, 2);
            if (oh > 23 || om > 59) throw bad("invalid offset");
            string off = s[p .. p + 6];
            p += 6;
            if (oh == 0 && om == 0)
                off = "Z";
            return Node.scalar(Kind.datetime, text ~ off);
        }
    }
    return Node.scalar(Kind.datetimeLocal, text);
}

private string parseTime(string s, ref size_t p)
{
    immutable h = digitsAt(s, p, 2);
    if (p + 8 > s.length || s[p + 2] != ':' || s[p + 5] != ':')
        throw bad("invalid time");
    immutable m = digitsAt(s, p + 3, 2);
    immutable sec = digitsAt(s, p + 6, 2);
    if (h > 23 || m > 59 || sec > 59) throw bad("invalid time");
    string base = s[p .. p + 8];
    p += 8;
    if (p < s.length && s[p] == '.')
    {
        size_t q = p + 1;
        while (q < s.length && isDigit(s[q])) ++q;
        if (q == p + 1) throw bad("empty fraction");
        size_t e = q;
        while (e > p + 1 && s[e - 1] == '0') --e;
        string r = e > p + 1 ? base ~ s[p .. e] : base;
        p = q;
        return r;
    }
    return base;
}
