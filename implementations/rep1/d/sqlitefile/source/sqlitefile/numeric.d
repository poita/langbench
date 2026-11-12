/// Parsing of numeric constants, shared by the query parser and the
/// column-affinity rules.
module sqlitefile.numeric;

import core.stdc.stdlib : strtod;
import sqlitefile.value;

@safe:

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Matches `[+-]? digits [. digits*] [eE [+-]? digits]` starting at `start`.
///
/// With `lenient`, the digits before the `.` may be omitted (`.5`), as in the
/// affinity conversion of strings; the query-literal grammar is strict.
/// Returns the index one past the match, or `start` if nothing matched.
/// `isReal` is set when the match has a `.` or an exponent.
size_t matchNumber(const(char)[] s, size_t start, bool lenient, out bool isReal) pure nothrow @nogc
{
    const n = s.length;
    size_t p = start;
    isReal = false;
    if (p < n && (s[p] == '+' || s[p] == '-'))
        p++;
    const digitsStart = p;
    while (p < n && isDigit(s[p]))
        p++;
    if (p > digitsStart)
    {
        if (p < n && s[p] == '.')
        {
            isReal = true;
            p++;
            while (p < n && isDigit(s[p]))
                p++;
        }
    }
    else if (lenient && p < n && s[p] == '.')
    {
        p++;
        const fracStart = p;
        while (p < n && isDigit(s[p]))
            p++;
        if (p == fracStart)
            return start;
        isReal = true;
    }
    else
        return start;

    if (p < n && (s[p] == 'e' || s[p] == 'E'))
    {
        size_t q = p + 1;
        if (q < n && (s[q] == '+' || s[q] == '-'))
            q++;
        const expStart = q;
        while (q < n && isDigit(s[q]))
            q++;
        if (q > expStart)
        {
            p = q;
            isReal = true;
        }
    }
    return p;
}

/// Converts text already validated by `matchNumber` into an INTEGER value
/// (when it has neither `.` nor exponent and fits in 64 bits) or a REAL.
Value numberFromText(const(char)[] s, bool isReal) @safe
{
    if (!isReal)
    {
        size_t p = 0;
        bool neg = false;
        if (s[0] == '+' || s[0] == '-')
        {
            neg = s[0] == '-';
            p = 1;
        }
        ulong acc = 0;
        bool overflow = false;
        for (; p < s.length; p++)
        {
            const d = s[p] - '0';
            if (acc > (ulong.max - d) / 10)
            {
                overflow = true;
                break;
            }
            acc = acc * 10 + d;
        }
        const limit = neg ? (1UL << 63) : (1UL << 63) - 1;
        if (!overflow && acc <= limit)
            return Value.fromInt(neg ? cast(long)(0UL - acc) : cast(long) acc);
    }
    return Value.fromReal(parseDouble(s));
}

/// Correctly rounded decimal → double conversion (via the C runtime).
double parseDouble(const(char)[] s) @trusted
{
    auto z = new char[s.length + 1];
    z[0 .. s.length] = s[];
    z[s.length] = 0;
    return strtod(z.ptr, null);
}

/// If `text`, with leading and trailing spaces/tabs removed, is entirely a
/// numeric constant (SPEC §3), returns it as a number.
bool textToNumber(const(char)[] text, out Value result)
{
    size_t b = 0, e = text.length;
    while (b < e && (text[b] == ' ' || text[b] == '\t'))
        b++;
    while (e > b && (text[e - 1] == ' ' || text[e - 1] == '\t'))
        e--;
    const t = text[b .. e];
    if (t.length == 0)
        return false;
    bool isReal;
    const end = matchNumber(t, 0, true, isReal);
    if (end != t.length)
        return false;
    result = numberFromText(t, isReal);
    return true;
}

unittest
{
    Value v;
    assert(textToNumber("42", v) && v.type == ValueType.integer && v.i == 42);
    assert(textToNumber(" 5 ", v) && v.type == ValueType.integer && v.i == 5);
    assert(textToNumber("\t-7\t", v) && v.i == -7);
    assert(textToNumber(".5", v) && v.type == ValueType.real_ && v.r == 0.5);
    assert(textToNumber("-.5", v) && v.r == -0.5);
    assert(textToNumber("5.", v) && v.type == ValueType.real_ && v.r == 5.0);
    assert(textToNumber("+5e0", v) && v.type == ValueType.real_ && v.r == 5.0);
    assert(textToNumber("9223372036854775807", v) && v.type == ValueType.integer
            && v.i == long.max);
    assert(textToNumber("-9223372036854775808", v) && v.type == ValueType.integer
            && v.i == long.min);
    assert(textToNumber("9223372036854775808", v) && v.type == ValueType.real_);
    assert(textToNumber("1e3", v) && v.r == 1000.0);
    foreach (bad; ["", "-", "0x10", "inf", "5 x", "1e", "1e+", ".", "+.e1", "--1", "nan"])
        assert(!textToNumber(bad, v), bad);
}

unittest
{
    bool r;
    assert(matchNumber("1.5", 0, false, r) == 3 && r);
    assert(matchNumber("1.", 0, false, r) == 2 && r);
    assert(matchNumber(".5", 0, false, r) == 0);
    assert(matchNumber("1e", 0, false, r) == 1 && !r);
    assert(matchNumber("-2.5e-3x", 0, false, r) == 7 && r);
    assert(matchNumber("12", 0, false, r) == 2 && !r);
}
