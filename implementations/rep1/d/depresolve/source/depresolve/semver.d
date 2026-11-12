/**
 * Semantic versions and version ranges.
 *
 * Only plain `MAJOR.MINOR.PATCH` versions are supported (no prerelease or
 * build metadata). Components are compared numerically.
 *
 * A `VersionRange` is always normalised to a half-open interval
 * `[lo, hi)`, which makes every range form of the input language
 * (`*`, exact, caret, tilde and comparator lists) the same cheap object.
 */
module depresolve.semver;

import std.conv : to;
import std.format : format;

/// Thrown when a version or range string is malformed.
class SyntaxException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A semantic version `major.minor.patch`.
struct Version
{
    uint major; /// Major component.
    uint minor; /// Minor component.
    uint patch; /// Patch component.

    /// Largest value a component may have when parsed.
    enum uint maxComponent = int.max;

    /// A version that compares greater than every parseable version.
    enum Version infinity = Version(uint.max, uint.max, uint.max);

    /// Numeric, component-wise comparison (major first).
    int opCmp(const Version o) const pure nothrow @nogc @safe
    {
        if (major != o.major) return major < o.major ? -1 : 1;
        if (minor != o.minor) return minor < o.minor ? -1 : 1;
        if (patch != o.patch) return patch < o.patch ? -1 : 1;
        return 0;
    }

    /// Equality (component-wise).
    bool opEquals(const Version o) const pure nothrow @nogc @safe
    {
        return major == o.major && minor == o.minor && patch == o.patch;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const pure nothrow @nogc @safe
    {
        return (cast(size_t) major * 1_000_003 + minor) * 1_000_003 + patch;
    }

    /// Formats as `major.minor.patch`.
    string toString() const @safe
    {
        return format("%s.%s.%s", major, minor, patch);
    }

    /// The smallest version strictly greater than this one.
    Version nextPatch() const pure nothrow @nogc @safe
    {
        return Version(major, minor, patch + 1);
    }

    /// Parses a complete `X.Y.Z` string. Throws `SyntaxException`.
    static Version parse(string s) @safe
    {
        size_t pos = 0;
        auto v = parsePrefix(s, pos);
        if (pos != s.length)
            throw new SyntaxException("trailing characters after version: " ~ s);
        return v;
    }

    /**
     * Parses a version starting at `pos`, advancing `pos` past it.
     * Throws `SyntaxException` on malformed input.
     */
    static Version parsePrefix(string s, ref size_t pos) @safe
    {
        Version v;
        v.major = parseNum(s, pos);
        expect(s, pos, '.');
        v.minor = parseNum(s, pos);
        expect(s, pos, '.');
        v.patch = parseNum(s, pos);
        return v;
    }
}

private void expect(string s, ref size_t pos, char c) @safe
{
    if (pos >= s.length || s[pos] != c)
        throw new SyntaxException("expected '" ~ c ~ "' in: " ~ s);
    ++pos;
}

private uint parseNum(string s, ref size_t pos) @safe
{
    immutable start = pos;
    ulong value = 0;
    while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
    {
        value = value * 10 + (s[pos] - '0');
        if (value > Version.maxComponent)
            throw new SyntaxException("version component too large in: " ~ s);
        ++pos;
    }
    if (pos == start)
        throw new SyntaxException("expected a number in: " ~ s);
    if (pos - start > 1 && s[start] == '0')
        throw new SyntaxException("leading zero in: " ~ s);
    return cast(uint) value;
}

/// A half-open interval `[lo, hi)` of versions.
struct VersionRange
{
    Version lo = Version(0, 0, 0); /// Inclusive lower bound.
    Version hi = Version.infinity; /// Exclusive upper bound.

    /// The range accepting every version (`*`).
    static VersionRange any() pure nothrow @nogc @safe
    {
        return VersionRange.init;
    }

    /// Whether `v` lies in the range.
    bool contains(const Version v) const pure nothrow @nogc @safe
    {
        return lo <= v && v < hi;
    }

    /// Whether no version can lie in the range.
    bool empty() const pure nothrow @nogc @safe
    {
        return !(lo < hi);
    }

    /**
     * Parses a range expression:
     * `*`, `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z`, or one or more space-separated
     * comparators `<V`, `<=V`, `>V`, `>=V` (all must hold).
     * Throws `SyntaxException`.
     */
    static VersionRange parse(string s) @safe
    {
        if (s.length == 0)
            throw new SyntaxException("empty range");
        if (s == "*")
            return any();

        immutable c = s[0];
        if (c >= '0' && c <= '9')
        {
            auto v = Version.parse(s);
            return VersionRange(v, v.nextPatch);
        }
        if (c == '^')
        {
            auto v = Version.parse(s[1 .. $]);
            Version hi;
            if (v.major > 0) hi = Version(v.major + 1, 0, 0);
            else if (v.minor > 0) hi = Version(0, v.minor + 1, 0);
            else hi = Version(0, 0, v.patch + 1);
            return VersionRange(v, hi);
        }
        if (c == '~')
        {
            auto v = Version.parse(s[1 .. $]);
            return VersionRange(v, Version(v.major, v.minor + 1, 0));
        }

        // Comparator list: intersect half-lines.
        VersionRange r;
        size_t pos = 0;
        for (;;)
        {
            if (pos >= s.length)
                throw new SyntaxException("expected comparator in: " ~ s);
            immutable op = s[pos];
            if (op != '<' && op != '>')
                throw new SyntaxException("unknown range syntax: " ~ s);
            ++pos;
            bool orEqual = false;
            if (pos < s.length && s[pos] == '=')
            {
                orEqual = true;
                ++pos;
            }
            auto v = Version.parsePrefix(s, pos);
            if (op == '<')
            {
                immutable bound = orEqual ? v.nextPatch : v;
                if (bound < r.hi) r.hi = bound;
            }
            else
            {
                immutable bound = orEqual ? v : v.nextPatch;
                if (bound > r.lo) r.lo = bound;
            }
            if (pos == s.length) break;
            expect(s, pos, ' ');
        }
        return r;
    }
}

@safe unittest
{
    assert(Version.parse("1.10.0") > Version.parse("1.9.0"));
    assert(Version.parse("0.0.0") < Version.parse("0.0.1"));
    assert(Version.parse("2.0.0") > Version.parse("1.999.999"));
    assert(Version.parse("1000000.1000000.1000000").toString == "1000000.1000000.1000000");
    assert(Version.parse("3.4.5") == Version(3, 4, 5));
}

@safe unittest
{
    import std.exception : assertThrown;
    foreach (bad; ["", "1", "1.2", "1.2.", "1.2.3.4", "01.2.3", "1.02.3", "a.b.c", "1.2.3 ",
                   "99999999999.0.0"])
        assertThrown!SyntaxException(Version.parse(bad), bad);
}

@safe unittest
{
    static VersionRange r(string s) { return VersionRange.parse(s); }
    static Version v(string s) { return Version.parse(s); }

    // wildcard
    assert(r("*").contains(v("0.0.0")));
    assert(r("*").contains(v("1000000.0.0")));

    // exact
    assert(r("1.2.3").contains(v("1.2.3")));
    assert(!r("1.2.3").contains(v("1.2.4")));
    assert(!r("1.2.3").contains(v("1.2.2")));

    // caret: leftmost non-zero component is fixed
    assert(r("^1.2.3").contains(v("1.2.3")));
    assert(r("^1.2.3").contains(v("1.99.0")));
    assert(!r("^1.2.3").contains(v("2.0.0")));
    assert(!r("^1.2.3").contains(v("1.2.2")));
    assert(r("^0.2.3").contains(v("0.2.9")));
    assert(!r("^0.2.3").contains(v("0.3.0")));
    assert(r("^0.0.3").contains(v("0.0.3")));
    assert(!r("^0.0.3").contains(v("0.0.4")));
    assert(!r("^0.0.3").contains(v("0.0.2")));

    // tilde: major and minor fixed
    assert(r("~1.2.0").contains(v("1.2.9")));
    assert(!r("~1.2.0").contains(v("1.3.0")));
    assert(r("~0.0.3").contains(v("0.0.9")));
    assert(!r("~0.0.3").contains(v("0.1.0")));

    // comparators
    assert(r("<2.0.0").contains(v("1.9.9")));
    assert(!r("<2.0.0").contains(v("2.0.0")));
    assert(r("<=2.0.0").contains(v("2.0.0")));
    assert(!r("<=2.0.0").contains(v("2.0.1")));
    assert(!r(">2.0.0").contains(v("2.0.0")));
    assert(r(">2.0.0").contains(v("2.0.1")));
    assert(r(">=2.0.0").contains(v("2.0.0")));
    assert(r(">=1.0.0 <2.0.0").contains(v("1.5.0")));
    assert(!r(">=1.0.0 <2.0.0").contains(v("2.0.0")));
    assert(!r(">=1.0.0 <2.0.0").contains(v("0.9.9")));
    assert(r(">1.0.0 <=1.0.5 >=1.0.2").contains(v("1.0.5")));
    assert(!r(">1.0.0 <=1.0.5 >=1.0.2").contains(v("1.0.1")));
    assert(r(">=2.0.0 <1.0.0").empty);
    assert(!r(">=2.0.0 <1.0.0").contains(v("1.5.0")));
}

@safe unittest
{
    import std.exception : assertThrown;
    foreach (bad; ["", "^", "~1.2", "<", ">=1.0.0 ", ">=1.0.0  <2.0.0", "=1.0.0", "<>1.0.0",
                   ">= 1.0.0", "^1.0"])
        assertThrown!SyntaxException(VersionRange.parse(bad), bad);
}
