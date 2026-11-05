/**
 * Semantic versions packed into a single integer key.
 *
 * A version `MAJOR.MINOR.PATCH` is packed into a `ulong` using 21 bits per
 * component, so that comparing two keys numerically compares the versions
 * component by component. 21 bits hold values up to 2,097,151, which leaves
 * room for the exclusive bounds that ranges produce (e.g. `1,000,001`).
 */
module depresolve.semver;

/// A packed version key; compares like the version it encodes.
alias VersionKey = ulong;

/// Number of bits used for each version component.
enum componentBits = 21;

/// Largest value a single component may take.
enum ulong maxComponent = (1UL << componentBits) - 1;

/// Largest key (an exclusive upper bound meaning "no upper bound").
enum VersionKey unboundedKey = ulong.max;

/// Packs three components into a key.
VersionKey packVersion(ulong major, ulong minor, ulong patch) @safe pure nothrow @nogc
in (major <= maxComponent && minor <= maxComponent && patch <= maxComponent)
{
    return (major << (2 * componentBits)) | (minor << componentBits) | patch;
}

/// Major component of `key`.
ulong majorOf(VersionKey key) @safe pure nothrow @nogc
{
    return key >> (2 * componentBits);
}

/// Minor component of `key`.
ulong minorOf(VersionKey key) @safe pure nothrow @nogc
{
    return (key >> componentBits) & maxComponent;
}

/// Patch component of `key`.
ulong patchOf(VersionKey key) @safe pure nothrow @nogc
{
    return key & maxComponent;
}

/**
 * Parses `MAJOR.MINOR.PATCH` from the start of `text`, advancing `text`
 * past the consumed characters.
 *
 * The input must be well formed; no validation beyond digit scanning is done.
 */
VersionKey parseVersion(ref const(char)[] text) @safe pure nothrow @nogc
{
    ulong[3] parts;
    foreach (i; 0 .. 3)
    {
        ulong n = 0;
        size_t j = 0;
        while (j < text.length && text[j] >= '0' && text[j] <= '9')
        {
            n = n * 10 + (text[j] - '0');
            ++j;
        }
        parts[i] = n;
        text = text[j .. $];
        if (i < 2 && text.length && text[0] == '.')
            text = text[1 .. $];
    }
    return packVersion(parts[0], parts[1], parts[2]);
}

/// Formats a key as `MAJOR.MINOR.PATCH`.
string formatVersion(VersionKey key) @safe pure
{
    import std.conv : to;

    return majorOf(key).to!string ~ "." ~ minorOf(key).to!string ~ "." ~ patchOf(key).to!string;
}
