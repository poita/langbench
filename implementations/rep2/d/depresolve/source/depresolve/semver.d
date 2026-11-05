/**
 * Semantic versions (`MAJOR.MINOR.PATCH`) and their packed integer keys.
 *
 * Every version is packed into a single 64-bit unsigned integer, 21 bits per
 * component, so that comparing two versions is one integer comparison. The
 * packing is monotone and has headroom above the largest legal component
 * (1,000,000), so the exclusive bounds that ranges produce, such as
 * `(X+1).0.0` or `X.(Y+1).0`, are ordinary keys too.
 */
module depresolve.semver;

import std.format : format;

/// Raised when input text is not well formed.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A version packed into one integer that orders like the version itself.
alias VersionKey = ulong;

/// Number of bits used for each component of a `VersionKey`.
enum componentBits = 21;

/// Largest component value a `Version` may hold (the SPEC limit).
enum uint maxComponent = 1_000_000;

/// Mask selecting one component of a `VersionKey`.
private enum ulong componentMask = (1UL << componentBits) - 1;

/// Pack three components into a key. Components up to `2^21 - 1` are accepted.
VersionKey packKey(uint major, uint minor, uint patch) pure nothrow @nogc @safe
{
    return (cast(ulong) major << (2 * componentBits))
        | (cast(ulong) minor << componentBits)
        | cast(ulong) patch;
}

/// A concrete version `MAJOR.MINOR.PATCH`.
struct Version
{
    uint major, minor, patch;

    /// The packed integer key of this version.
    VersionKey key() const pure nothrow @nogc @safe
    {
        return packKey(major, minor, patch);
    }

    /// Recover a version from a key produced by `key`.
    static Version fromKey(VersionKey k) pure nothrow @nogc @safe
    {
        return Version(cast(uint)((k >> (2 * componentBits)) & componentMask),
                       cast(uint)((k >> componentBits) & componentMask),
                       cast(uint)(k & componentMask));
    }

    /// Numeric, component-wise ordering.
    int opCmp(const Version rhs) const pure nothrow @nogc @safe
    {
        immutable a = key, b = rhs.key;
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    /// `MAJOR.MINOR.PATCH`
    string toString() const pure @safe
    {
        return format("%d.%d.%d", major, minor, patch);
    }
}

/**
 * Parse `MAJOR.MINOR.PATCH` strictly: three decimal numbers without leading
 * zeros, no whitespace, no prerelease or build suffix.
 *
 * Throws: `ParseException`
 */
Version parseVersion(const(char)[] text) pure @safe
{
    uint[3] parts;
    size_t i = 0;
    foreach (p; 0 .. 3)
    {
        immutable start = i;
        ulong value = 0;
        while (i < text.length && text[i] >= '0' && text[i] <= '9')
        {
            value = value * 10 + (text[i] - '0');
            if (value > componentMask)
                throw new ParseException("version component too large: " ~ text.idup);
            ++i;
        }
        immutable digits = i - start;
        if (digits == 0 || (digits > 1 && text[start] == '0'))
            throw new ParseException("malformed version: '" ~ text.idup ~ "'");
        parts[p] = cast(uint) value;
        if (p < 2)
        {
            if (i >= text.length || text[i] != '.')
                throw new ParseException("malformed version: '" ~ text.idup ~ "'");
            ++i;
        }
    }
    if (i != text.length)
        throw new ParseException("malformed version: '" ~ text.idup ~ "'");
    return Version(parts[0], parts[1], parts[2]);
}
