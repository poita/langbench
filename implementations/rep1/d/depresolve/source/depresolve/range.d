/**
 * Version ranges, reduced to a single half-open interval of version keys.
 *
 * Every range of the requirement grammar (`*`, exact, `^`, `~` and one to
 * three comparators) denotes a contiguous set of versions, so it is
 * represented as `[lo, hi)` over packed `VersionKey`s. Comparators are
 * intersected while parsing; an empty interval accepts nothing.
 */
module depresolve.range;

import depresolve.semver;

/// A half-open interval `[lo, hi)` of version keys.
struct Interval
{
    VersionKey lo = 0;
    VersionKey hi = unboundedKey;

    /// True when no version can lie in the interval.
    bool empty() const @safe pure nothrow @nogc
    {
        return hi <= lo;
    }

    /// True when `key` lies in the interval.
    bool contains(VersionKey key) const @safe pure nothrow @nogc
    {
        return key >= lo && key < hi;
    }
}

/**
 * Parses a range such as `*`, `1.2.3`, `^1.2.3`, `~1.2.3` or
 * `>=1.0.0 <2.0.0` into an `Interval`.
 */
Interval parseRange(const(char)[] text) @safe pure nothrow @nogc
{
    Interval iv;
    if (text.length == 0 || text[0] == '*')
        return iv;

    const c = text[0];
    if (c == '^' || c == '~')
    {
        auto rest = text[1 .. $];
        const key = parseVersion(rest);
        const major = majorOf(key), minor = minorOf(key);
        iv.lo = key;
        if (c == '~')
            iv.hi = packVersion(major, minor + 1, 0);
        else if (major > 0)
            iv.hi = packVersion(major + 1, 0, 0);
        else if (minor > 0)
            iv.hi = packVersion(0, minor + 1, 0);
        else
            iv.hi = key + 1;
        return iv;
    }
    if (c >= '0' && c <= '9')
    {
        auto rest = text;
        const key = parseVersion(rest);
        iv.lo = key;
        iv.hi = key + 1;
        return iv;
    }

    // One or more space-separated comparators, all of which must hold.
    auto rest = text;
    while (rest.length)
    {
        const lt = rest[0] == '<';
        rest = rest[1 .. $];
        bool orEqual = false;
        if (rest.length && rest[0] == '=')
        {
            orEqual = true;
            rest = rest[1 .. $];
        }
        const key = parseVersion(rest);
        if (lt)
        {
            const bound = orEqual ? key + 1 : key;
            if (bound < iv.hi)
                iv.hi = bound;
        }
        else
        {
            const bound = orEqual ? key : key + 1;
            if (bound > iv.lo)
                iv.lo = bound;
        }
        if (rest.length && rest[0] == ' ')
            rest = rest[1 .. $];
    }
    return iv;
}
