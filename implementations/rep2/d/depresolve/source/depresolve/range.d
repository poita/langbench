/**
 * Version ranges (`*`, exact, `^`, `~` and comparator lists) with npm
 * semantics, normalised to a half-open interval `[lo, hi)` of versions.
 */
module depresolve.range;

import depresolve.semver;

/**
 * A set of versions expressed as the half-open interval `[lo, hi)`.
 *
 * Every range syntax supported by the resolver is representable this way,
 * including empty ranges such as `>=2.0.0 <1.0.0` (`lo >= hi`).
 */
struct VersionRange
{
    /// Inclusive lower bound.
    Version lo = Version.min;
    /// Exclusive upper bound.
    Version hi = Version.infinity;

    /// True if `v` lies in `[lo, hi)`.
    bool matches(const Version v) const pure nothrow @nogc @safe
    {
        return lo <= v && v < hi;
    }

    /// True if no version at all can satisfy this range.
    bool empty() const pure nothrow @nogc @safe
    {
        return lo >= hi;
    }

    /// Intersection of two ranges.
    VersionRange intersect(const VersionRange o) const pure nothrow @nogc @safe
    {
        return VersionRange(lo > o.lo ? lo : o.lo, hi < o.hi ? hi : o.hi);
    }
}

/// The range accepting every version (`*`).
VersionRange anyVersion() pure nothrow @nogc @safe
{
    return VersionRange.init;
}

/// Range accepting exactly `v`.
VersionRange exactly(Version v) pure nothrow @nogc @safe
{
    return VersionRange(v, v.nextPatch);
}

/// Caret range: keeps the leftmost non-zero component fixed.
VersionRange caret(Version v) pure nothrow @nogc @safe
{
    if (v.major > 0) return VersionRange(v, Version(v.major + 1, 0, 0));
    if (v.minor > 0) return VersionRange(v, Version(0, v.minor + 1, 0));
    return VersionRange(v, Version(0, 0, v.patch + 1));
}

/// Tilde range: keeps major and minor fixed.
VersionRange tilde(Version v) pure nothrow @nogc @safe
{
    return VersionRange(v, Version(v.major, v.minor + 1, 0));
}

/**
 * Parses a range from `text[pos .. $]`, advancing `pos` to the first
 * character that cannot continue the range (a `,`, a newline, or the end).
 *
 * Throws: `ParseException` on malformed input.
 */
VersionRange parseRangeAt(const(char)[] text, ref size_t pos) pure @safe
{
    import std.conv : to;

    if (pos >= text.length)
        throw new ParseException("expected a range at end of input");
    const c = text[pos];
    switch (c)
    {
    case '*':
        ++pos;
        return anyVersion();
    case '^':
        ++pos;
        return caret(parseVersionAt(text, pos));
    case '~':
        ++pos;
        return tilde(parseVersionAt(text, pos));
    case '0': .. case '9':
        return exactly(parseVersionAt(text, pos));
    case '<', '>':
        auto r = anyVersion();
        while (true)
        {
            const op = text[pos++];
            const orEqual = pos < text.length && text[pos] == '=';
            if (orEqual) ++pos;
            const v = parseVersionAt(text, pos);
            VersionRange cmp;
            if (op == '<')
                cmp = orEqual ? VersionRange(Version.min, v.nextPatch)
                              : VersionRange(Version.min, v);
            else
                cmp = orEqual ? VersionRange(v, Version.infinity)
                              : VersionRange(v.nextPatch, Version.infinity);
            r = r.intersect(cmp);
            if (pos + 1 < text.length && text[pos] == ' '
                && (text[pos + 1] == '<' || text[pos + 1] == '>'))
                ++pos;
            else
                break;
        }
        return r;
    default:
        throw new ParseException("unexpected character in range at offset " ~ pos.to!string);
    }
}

/// Parses a complete range string such as `"^1.2.3"` or `">=1.0.0 <2.0.0"`.
VersionRange parseRange(const(char)[] text) pure @safe
{
    size_t pos = 0;
    auto r = parseRangeAt(text, pos);
    if (pos != text.length)
        throw new ParseException("trailing characters after range: " ~ text.idup);
    return r;
}

unittest
{
    auto v(string s) { return parseVersion(s); }

    assert(parseRange("*").matches(v("0.0.0")));
    assert(parseRange("*").matches(v("999999.0.1")));

    auto ex = parseRange("1.2.3");
    assert(ex.matches(v("1.2.3")) && !ex.matches(v("1.2.4")) && !ex.matches(v("1.2.2")));
}

unittest
{
    auto v(string s) { return parseVersion(s); }

    // caret
    auto c1 = parseRange("^1.2.3");
    assert(c1.matches(v("1.2.3")) && c1.matches(v("1.99.0")));
    assert(!c1.matches(v("1.2.2")) && !c1.matches(v("2.0.0")));
    auto c2 = parseRange("^0.2.3");
    assert(c2.matches(v("0.2.9")) && !c2.matches(v("0.3.0")) && !c2.matches(v("0.2.2")));
    auto c3 = parseRange("^0.0.3");
    assert(c3.matches(v("0.0.3")) && !c3.matches(v("0.0.4")) && !c3.matches(v("0.0.2")));
    auto c4 = parseRange("^0.0.0");
    assert(c4.matches(v("0.0.0")) && !c4.matches(v("0.0.1")));

    // tilde
    auto t1 = parseRange("~1.2.3");
    assert(t1.matches(v("1.2.9")) && !t1.matches(v("1.3.0")) && !t1.matches(v("1.2.2")));
    auto t2 = parseRange("~0.0.3");
    assert(t2.matches(v("0.0.9")) && t2.matches(v("0.0.3")) && !t2.matches(v("0.1.0")));
}

unittest
{
    auto v(string s) { return parseVersion(s); }

    auto r = parseRange(">=1.0.0 <2.0.0");
    assert(r.matches(v("1.0.0")) && r.matches(v("1.9.9")) && !r.matches(v("2.0.0")));
    auto g = parseRange(">1.0.0");
    assert(!g.matches(v("1.0.0")) && g.matches(v("1.0.1")));
    auto l = parseRange("<=1.0.0");
    assert(l.matches(v("1.0.0")) && !l.matches(v("1.0.1")));
    assert(parseRange(">=2.0.0 <1.0.0").empty);
    auto three = parseRange(">0.5.0 <=1.0.0 <0.9.0");
    assert(three.matches(v("0.6.0")) && !three.matches(v("0.9.0")) && !three.matches(v("0.5.0")));
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseRange(""));
    assertThrown!ParseException(parseRange("^1.2"));
    assertThrown!ParseException(parseRange("=1.2.3"));
    assertThrown!ParseException(parseRange("*x"));
}
