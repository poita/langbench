/**
 * Version ranges, reduced to half-open intervals of version keys.
 *
 * Every range of the grammar (`*`, exact, `^`, `~`, and one to three
 * comparators) denotes a set of the form `[lo, hi)` over `VersionKey`s, so
 * matching a version is two integer comparisons.
 */
module depresolve.range;

import depresolve.semver;

/// A half-open interval `[lo, hi)` of version keys. Empty when `lo >= hi`.
struct Interval
{
    VersionKey lo = 0;
    VersionKey hi = VersionKey.max;

    /// True if no version can lie in the interval.
    bool empty() const pure nothrow @nogc @safe
    {
        return lo >= hi;
    }

    /// True if `key` lies in `[lo, hi)`.
    bool contains(VersionKey key) const pure nothrow @nogc @safe
    {
        return key >= lo && key < hi;
    }

    /// True if `v` lies in the interval.
    bool contains(Version v) const pure nothrow @nogc @safe
    {
        return contains(v.key);
    }

    /// The set intersection of two intervals.
    Interval intersect(Interval other) const pure nothrow @nogc @safe
    {
        return Interval(lo > other.lo ? lo : other.lo, hi < other.hi ? hi : other.hi);
    }
}

/// The interval accepting every version (`*`).
enum Interval anyVersion = Interval(0, VersionKey.max);

/**
 * Parse a range expression into an interval.
 *
 * Supported forms: `*`, `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z`, and one or more
 * space-separated comparators `<V`, `<=V`, `>V`, `>=V` (all must hold).
 * Caret and tilde follow npm semantics; see the project SPEC.
 *
 * Throws: `ParseException` on malformed text.
 */
Interval parseRange(const(char)[] text) pure @safe
{
    if (text.length == 0)
        throw new ParseException("empty range");
    switch (text[0])
    {
    case '*':
        if (text.length != 1)
            throw new ParseException("malformed range: '" ~ text.idup ~ "'");
        return anyVersion;
    case '^':
        return caret(parseVersion(text[1 .. $]));
    case '~':
        return tilde(parseVersion(text[1 .. $]));
    case '<', '>':
        return parseComparators(text);
    default:
        return exact(parseVersion(text));
    }
}

/// Interval accepting exactly `v`.
Interval exact(Version v) pure nothrow @nogc @safe
{
    return Interval(v.key, v.key + 1);
}

/// `^v`: keep the leftmost non-zero component fixed.
Interval caret(Version v) pure nothrow @nogc @safe
{
    VersionKey hi;
    if (v.major > 0)
        hi = packKey(v.major + 1, 0, 0);
    else if (v.minor > 0)
        hi = packKey(0, v.minor + 1, 0);
    else
        hi = packKey(0, 0, v.patch + 1);
    return Interval(v.key, hi);
}

/// `~v`: keep major and minor fixed.
Interval tilde(Version v) pure nothrow @nogc @safe
{
    return Interval(v.key, packKey(v.major, v.minor + 1, 0));
}

private Interval parseComparators(const(char)[] text) pure @safe
{
    auto result = anyVersion;
    while (true)
    {
        size_t end = 0;
        while (end < text.length && text[end] != ' ')
            ++end;
        result = result.intersect(parseComparator(text[0 .. end]));
        if (end == text.length)
            return result;
        text = text[end + 1 .. $];
    }
}

private Interval parseComparator(const(char)[] c) pure @safe
{
    if (c.length < 2)
        throw new ParseException("malformed comparator: '" ~ c.idup ~ "'");
    immutable bool orEqual = c[1] == '=';
    immutable opLen = orEqual ? 2 : 1;
    immutable key = parseVersion(c[opLen .. $]).key;
    switch (c[0])
    {
    case '<':
        return Interval(0, orEqual ? key + 1 : key);
    case '>':
        return Interval(orEqual ? key : key + 1, VersionKey.max);
    default:
        throw new ParseException("malformed comparator: '" ~ c.idup ~ "'");
    }
}
