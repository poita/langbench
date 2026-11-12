/**
 * Semantic versions (`MAJOR.MINOR.PATCH`, no prerelease or build suffixes).
 *
 * Components are compared numerically, so `1.10.0` is newer than `1.9.0`.
 */
module depresolve.semver;

import std.conv : to;

/// Thrown when text cannot be parsed as a version, range or registry.
class ParseException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A `MAJOR.MINOR.PATCH` version. Ordered numerically, major component first.
struct Version
{
    /// Version components.
    uint major, minor, patch;

    /// Numeric, component-wise ordering.
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

    /// Formats as `MAJOR.MINOR.PATCH`.
    string toString() const pure @safe
    {
        return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
    }

    /// The smallest version: `0.0.0`.
    static Version min() pure nothrow @nogc @safe { return Version(0, 0, 0); }

    /// A version greater than any real one (used as an open upper bound).
    static Version infinity() pure nothrow @nogc @safe
    {
        return Version(uint.max, uint.max, uint.max);
    }

    /// The next version after this one in patch order (`1.2.3` -> `1.2.4`).
    Version nextPatch() const pure nothrow @nogc @safe
    {
        return Version(major, minor, patch + 1);
    }
}

/**
 * Parses a version from `text[pos .. $]`, advancing `pos` past it.
 *
 * Throws: `ParseException` on malformed input.
 */
Version parseVersionAt(const(char)[] text, ref size_t pos) pure @safe
{
    Version v;
    v.major = parseNum(text, pos);
    expect(text, pos, '.');
    v.minor = parseNum(text, pos);
    expect(text, pos, '.');
    v.patch = parseNum(text, pos);
    return v;
}

/// Parses a complete version string such as `"1.20.3"`.
Version parseVersion(const(char)[] text) pure @safe
{
    size_t pos = 0;
    auto v = parseVersionAt(text, pos);
    if (pos != text.length)
        throw new ParseException("trailing characters after version: " ~ text.idup);
    return v;
}

package uint parseNum(const(char)[] text, ref size_t pos) pure @safe
{
    size_t start = pos;
    ulong n = 0;
    while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
    {
        n = n * 10 + (text[pos] - '0');
        if (n > uint.max - 1)
            throw new ParseException("number too large");
        ++pos;
    }
    if (pos == start)
        throw new ParseException("expected a number at offset " ~ start.to!string);
    return cast(uint) n;
}

package void expect(const(char)[] text, ref size_t pos, char c) pure @safe
{
    if (pos >= text.length || text[pos] != c)
        throw new ParseException("expected '" ~ c ~ "' at offset " ~ pos.to!string);
    ++pos;
}

unittest
{
    assert(parseVersion("1.2.3") == Version(1, 2, 3));
    assert(parseVersion("0.0.0") == Version.min);
    assert(parseVersion("1.10.0") > parseVersion("1.9.0"));
    assert(parseVersion("2.0.0") > parseVersion("1.999999.999999"));
    assert(Version(1, 2, 3).toString == "1.2.3");
    assert(Version(1, 2, 3).nextPatch == Version(1, 2, 4));
    assert(Version(1, 2, 3) < Version.infinity);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseVersion("1.2"));
    assertThrown!ParseException(parseVersion("1.2.3.4"));
    assertThrown!ParseException(parseVersion("a.b.c"));
    assertThrown!ParseException(parseVersion(""));
}
