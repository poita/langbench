/**
 * Version ranges, reduced to half-open intervals of packed version keys.
 *
 * Every range in the input language (`*`, exact, `^`, `~`, and one to three
 * comparators) denotes a single contiguous interval of versions, so a range
 * is represented as `[lo, hi)` over `Version.key`.
 */
module depresolve.range;

import depresolve.semver;

/// A half-open interval `[lo, hi)` of version keys.
struct Interval
{
    /// Inclusive lower bound.
    ulong lo = 0;
    /// Exclusive upper bound.
    ulong hi = ulong.max;

    /// True when no version can lie in the interval.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return hi <= lo;
    }

    /// True when `v` lies in the interval.
    bool contains(Version v) const pure nothrow @nogc @safe
    {
        return v.key >= lo && v.key < hi;
    }

    /// Narrows this interval to its intersection with `other`.
    void intersect(Interval other) pure nothrow @nogc @safe
    {
        if (other.lo > lo)
            lo = other.lo;
        if (other.hi < hi)
            hi = other.hi;
    }
}

/// Thrown when range or version text is malformed.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The interval accepted by `^v` (npm caret semantics).
Interval caret(Version v) pure nothrow @nogc @safe
{
    if (v.major > 0)
        return Interval(v.key, Version(v.major + 1, 0, 0).key);
    if (v.minor > 0)
        return Interval(v.key, Version(0, v.minor + 1, 0).key);
    return Interval(v.key, Version(0, 0, v.patch + 1).key);
}

/// The interval accepted by `~v` (npm tilde semantics).
Interval tilde(Version v) pure nothrow @nogc @safe
{
    return Interval(v.key, Version(v.major, v.minor + 1, 0).key);
}

/// The interval accepted by the exact range `v`.
Interval exact(Version v) pure nothrow @nogc @safe
{
    return Interval(v.key, v.key + 1);
}

/// Parses `num "." num "." num` starting at `pos`, advancing `pos` past it.
Version parseVersion(const(char)[] s, ref size_t pos) pure @safe
{
    ulong[3] parts;
    foreach (i; 0 .. 3)
    {
        if (i > 0)
        {
            if (pos >= s.length || s[pos] != '.')
                throw new ParseException("expected '.' in version");
            ++pos;
        }
        const start = pos;
        ulong n = 0;
        while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
        {
            n = n * 10 + (s[pos] - '0');
            if (n > maxComponent)
                throw new ParseException("version component too large");
            ++pos;
        }
        if (pos == start)
            throw new ParseException("expected digits in version");
        parts[i] = n;
    }
    return Version(parts[0], parts[1], parts[2]);
}

/// Parses a version from a whole string.
Version parseVersion(const(char)[] s) pure @safe
{
    size_t pos = 0;
    auto v = parseVersion(s, pos);
    if (pos != s.length)
        throw new ParseException("trailing characters after version");
    return v;
}

/**
 * Parses a range starting at `pos`, advancing `pos` to the first character
 * that cannot belong to it (a `,`, a newline, or the end of `s`).
 */
Interval parseRange(const(char)[] s, ref size_t pos) pure @safe
{
    if (pos >= s.length)
        throw new ParseException("expected range");
    const c = s[pos];
    switch (c)
    {
    case '*':
        ++pos;
        return Interval.init;
    case '^':
        ++pos;
        return caret(parseVersion(s, pos));
    case '~':
        ++pos;
        return tilde(parseVersion(s, pos));
    case '0': .. case '9':
        return exact(parseVersion(s, pos));
    case '<', '>':
        Interval result;
        while (true)
        {
            const op = s[pos++];
            const orEqual = pos < s.length && s[pos] == '=';
            if (orEqual)
                ++pos;
            const v = parseVersion(s, pos);
            Interval cmp;
            if (op == '<')
                cmp.hi = orEqual ? v.key + 1 : v.key;
            else
                cmp.lo = orEqual ? v.key : v.key + 1;
            result.intersect(cmp);
            if (pos < s.length && s[pos] == ' ' && pos + 1 < s.length
                && (s[pos + 1] == '<' || s[pos + 1] == '>'))
                ++pos;
            else
                break;
        }
        return result;
    default:
        throw new ParseException("unrecognised range");
    }
}

/// Parses a range from a whole string.
Interval parseRange(const(char)[] s) pure @safe
{
    size_t pos = 0;
    auto r = parseRange(s, pos);
    if (pos != s.length)
        throw new ParseException("trailing characters after range");
    return r;
}
