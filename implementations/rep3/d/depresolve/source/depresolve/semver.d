/**
 * Semantic versions packed into a single integer key.
 *
 * A version `MAJOR.MINOR.PATCH` is encoded as three 21-bit fields in one
 * `ulong`, so comparing two versions is a single integer comparison. 21 bits
 * hold every value up to 2,097,151, which leaves room for the exclusive
 * bounds that ranges produce (a component of 1,000,001 for inputs whose
 * components are at most 1,000,000).
 */
module depresolve.semver;

import std.conv : to;

/// Number of bits used for each version component inside a key.
enum componentBits = 21;
/// Largest component value that can be stored in a key.
enum maxComponent = (1UL << componentBits) - 1;

/// A version `MAJOR.MINOR.PATCH`, stored as a packed, order-preserving key.
struct Version
{
    /// The packed key; `a.key < b.key` iff `a` is an older version than `b`.
    ulong key;

    /// Builds a version from its three components (each at most `maxComponent`).
    this(ulong major, ulong minor, ulong patch) pure nothrow @nogc @safe
    in (major <= maxComponent && minor <= maxComponent && patch <= maxComponent)
    {
        key = (major << (2 * componentBits)) | (minor << componentBits) | patch;
    }

    /// Wraps an already packed key.
    static Version fromKey(ulong key) pure nothrow @nogc @safe
    {
        Version v;
        v.key = key;
        return v;
    }

    /// The major component.
    @property ulong major() const pure nothrow @nogc @safe
    {
        return key >> (2 * componentBits);
    }

    /// The minor component.
    @property ulong minor() const pure nothrow @nogc @safe
    {
        return (key >> componentBits) & maxComponent;
    }

    /// The patch component.
    @property ulong patch() const pure nothrow @nogc @safe
    {
        return key & maxComponent;
    }

    /// Numeric comparison (major, then minor, then patch).
    int opCmp(const Version rhs) const pure nothrow @nogc @safe
    {
        return key < rhs.key ? -1 : (key > rhs.key ? 1 : 0);
    }

    /// Equality of versions.
    bool opEquals(const Version rhs) const pure nothrow @nogc @safe
    {
        return key == rhs.key;
    }

    /// Formats as `MAJOR.MINOR.PATCH`.
    string toString() const pure @safe
    {
        return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
    }
}

///
@safe pure unittest
{
    assert(Version(1, 10, 0) > Version(1, 9, 0));
    assert(Version(1, 2, 3).toString == "1.2.3");
}
