/// Integer and float literals: validation, conversion and canonical formatting.
module toml.number;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import toml.node : Kind;

private bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }

private int hexValue(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Formats an unsigned magnitude as decimal text, with an optional leading minus.
string formatInteger(ulong magnitude, bool negative) pure nothrow @safe
{
    char[21] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    } while (magnitude);
    if (negative) buf[--i] = '-';
    return buf[i .. $].idup;
}

/// Scans `[0-9] ("_"? [0-9])*` starting at `i`; leading zeros allowed.
private bool scanDigits(const(char)[] t, ref size_t i) pure nothrow @safe @nogc
{
    if (i >= t.length || !isDigit(t[i])) return false;
    i++;
    while (i < t.length)
    {
        if (isDigit(t[i])) i++;
        else if (t[i] == '_' && i + 1 < t.length && isDigit(t[i + 1])) i += 2;
        else break;
    }
    return true;
}

/// Scans a decimal integer part: `"0" | [1-9] ("_"? [0-9])*`.
private bool scanDecimalInt(const(char)[] t, ref size_t i) pure nothrow @safe @nogc
{
    if (i >= t.length || !isDigit(t[i])) return false;
    if (t[i] == '0') { i++; return true; }
    return scanDigits(t, i);
}

/// Parses an integer in base 2, 8 or 16 whose digits start at `t[i]`.
private bool parsePrefixed(const(char)[] t, size_t i, uint base, out ulong value) pure nothrow @safe @nogc
{
    value = 0;
    bool needDigit = true;
    bool lastUnderscore = false;
    for (; i < t.length; i++)
    {
        immutable c = t[i];
        if (c == '_')
        {
            if (needDigit) return false;
            needDigit = true;
            lastUnderscore = true;
            continue;
        }
        immutable d = hexValue(c);
        if (d < 0 || d >= base) return false;
        needDigit = false;
        lastUnderscore = false;
        if (value > (long.max - d) / base) return false;
        value = value * base + d;
    }
    return !needDigit && !lastUnderscore;
}

/**
 * Classifies and converts a bare numeric token.
 *
 * Params:
 *   t = the token text exactly as written in the document
 *   kind = set to `Kind.integer` or `Kind.float_` on success
 *   text = set to the canonical text on success
 * Returns: false when the token is not a valid TOML integer or float.
 */
bool parseNumber(const(char)[] t, out Kind kind, out string text) 
{
    if (t.length == 0) return false;
    size_t i = 0;
    bool neg = false, signed = false;
    if (t[0] == '+' || t[0] == '-')
    {
        signed = true;
        neg = t[0] == '-';
        i = 1;
    }
    auto rest = t[i .. $];
    if (rest == "inf") { kind = Kind.float_; text = neg ? "-inf" : "inf"; return true; }
    if (rest == "nan") { kind = Kind.float_; text = "nan"; return true; }

    if (!signed && t.length > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'o' || t[1] == 'b'))
    {
        immutable base = t[1] == 'x' ? 16u : t[1] == 'o' ? 8u : 2u;
        ulong v;
        if (!parsePrefixed(t, 2, base, v)) return false;
        kind = Kind.integer;
        text = formatInteger(v, false);
        return true;
    }

    // Decimal integer or float.
    size_t j = i;
    if (!scanDecimalInt(t, j)) return false;
    if (j == t.length)
    {
        ulong mag = 0;
        immutable limit = neg ? (cast(ulong) long.max) + 1 : cast(ulong) long.max;
        foreach (c; t[i .. $])
        {
            if (c == '_') continue;
            immutable d = c - '0';
            if (mag > (limit - d) / 10) return false;
            mag = mag * 10 + d;
        }
        kind = Kind.integer;
        text = formatInteger(mag, neg && mag != 0);
        return true;
    }
    if (t[j] == '.')
    {
        j++;
        if (!scanDigits(t, j)) return false;
    }
    if (j < t.length && (t[j] == 'e' || t[j] == 'E'))
    {
        j++;
        if (j < t.length && (t[j] == '+' || t[j] == '-')) j++;
        if (!scanDigits(t, j)) return false;
    }
    if (j != t.length) return false;

    // Strip underscores, convert with the C library's correctly rounded strtod.
    char[] clean = new char[t.length + 1];
    size_t n = 0;
    foreach (c; t)
        if (c != '_') clean[n++] = c;
    clean[n] = 0;
    immutable double d = (() @trusted => strtod(clean.ptr, null))();
    kind = Kind.float_;
    text = formatFloat(d);
    return true;
}

/**
 * Canonical text of a double: `nan`, `inf`, `-inf`, or exactly 17 significant
 * digits in scientific notation (`%.16e`).
 */
string formatFloat(double d) @trusted
{
    if (d != d) return "nan";
    if (d == double.infinity) return "inf";
    if (d == -double.infinity) return "-inf";
    char[40] buf;
    immutable n = snprintf(buf.ptr, buf.length, "%.16e", d);
    return buf[0 .. n].idup;
}

/// Converts canonical float text (as stored in a `Node`) back to a double.
double textToDouble(const(char)[] text) @trusted
{
    switch (text)
    {
    case "inf":  return double.infinity;
    case "-inf": return -double.infinity;
    case "nan":  return double.nan;
    default:
    }
    char[] z = new char[text.length + 1];
    z[0 .. text.length] = text[];
    z[text.length] = 0;
    return strtod(z.ptr, null);
}
