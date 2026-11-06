/// Column type affinity and the conversion of query literals (SPEC Part 3).
module sqlitefile.affinity;

import core.stdc.stdlib : strtod;
import sqlitefile.output;
import sqlitefile.value;

@safe:

/// A column's type affinity.
enum Affinity : ubyte
{
    integer,
    text,
    blob,
    real_,
    numeric,
}

private bool containsCI(string hay, string needle) pure nothrow @nogc
{
    if (needle.length > hay.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
    {
        bool ok = true;
        foreach (j; 0 .. needle.length)
        {
            char c = hay[i + j];
            if (c >= 'a' && c <= 'z')
                c = cast(char)(c - 32);
            if (c != needle[j])
            {
                ok = false;
                break;
            }
        }
        if (ok)
            return true;
    }
    return false;
}

/// Derives the affinity from a declared type using SQLite's five rules, in order.
Affinity affinityOf(string declaredType) pure nothrow @nogc
{
    if (containsCI(declaredType, "INT"))
        return Affinity.integer;
    if (containsCI(declaredType, "CHAR") || containsCI(declaredType, "CLOB")
        || containsCI(declaredType, "TEXT"))
        return Affinity.text;
    if (declaredType.length == 0 || containsCI(declaredType, "BLOB"))
        return Affinity.blob;
    if (containsCI(declaredType, "REAL") || containsCI(declaredType, "FLOA")
        || containsCI(declaredType, "DOUB"))
        return Affinity.real_;
    return Affinity.numeric;
}

/// Converts decimal text to a double with the C library's correctly rounded `strtod`.
double parseDouble(const(char)[] s) @trusted nothrow
{
    char[] z = new char[s.length + 1];
    z[0 .. s.length] = s[];
    z[s.length] = 0;
    return strtod(z.ptr, null);
}

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Tries to read `text` as a numeric constant (SPEC §3): optional surrounding
/// spaces and tabs, `[+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?`.
/// On success `result` is an INTEGER (no point/exponent and fits in 64 bits)
/// or a REAL.
bool parseNumericConstant(const(char)[] text, out Value result) nothrow
{
    size_t b = 0, e = text.length;
    while (b < e && (text[b] == ' ' || text[b] == '\t'))
        b++;
    while (e > b && (text[e - 1] == ' ' || text[e - 1] == '\t'))
        e--;
    auto s = text[b .. e];
    size_t i = 0;
    bool neg = false;
    if (i < s.length && (s[i] == '+' || s[i] == '-'))
        neg = s[i++] == '-';
    immutable intStart = i;
    while (i < s.length && isDigit(s[i]))
        i++;
    immutable intDigits = i - intStart;
    bool isReal = false;
    size_t fracDigits = 0;
    if (i < s.length && s[i] == '.')
    {
        isReal = true;
        i++;
        immutable fs = i;
        while (i < s.length && isDigit(s[i]))
            i++;
        fracDigits = i - fs;
    }
    if (intDigits == 0 && fracDigits == 0)
        return false;
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        isReal = true;
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-'))
            i++;
        immutable es = i;
        while (i < s.length && isDigit(s[i]))
            i++;
        if (i == es)
            return false;
    }
    if (i != s.length)
        return false;
    if (!isReal)
    {
        ulong mag = 0;
        bool overflow = false;
        foreach (c; s[intStart .. $])
        {
            immutable d = c - '0';
            if (mag > (ulong.max - d) / 10)
            {
                overflow = true;
                break;
            }
            mag = mag * 10 + d;
        }
        if (!overflow)
        {
            if (!neg && mag <= long.max)
            {
                result = Value.makeInt(cast(long) mag);
                return true;
            }
            if (neg && mag <= cast(ulong) long.max + 1)
            {
                result = Value.makeInt(cast(long)(0UL - mag));
                return true;
            }
        }
    }
    result = Value.makeReal(parseDouble(s));
    return true;
}

/// Applies a column's affinity to a query literal before comparison (SPEC §3).
Value applyAffinity(Value lit, Affinity aff) nothrow
{
    switch (aff)
    {
    case Affinity.text:
        if (lit.kind == ValueKind.integer || lit.kind == ValueKind.real_)
        {
            OutBuf o;
            appendValue(o, lit);
            return Value.makeText(o.data.idup);
        }
        return lit;
    case Affinity.integer:
    case Affinity.real_:
    case Affinity.numeric:
        if (lit.kind == ValueKind.text)
        {
            Value num;
            if (parseNumericConstant(cast(const(char)[]) lit.bytes, num))
                return num;
        }
        return lit;
    default:
        return lit;
    }
}
