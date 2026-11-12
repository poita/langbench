/// A 256-bit character set used for classes and the first-character table.
module btregex.charset;

/// Set of byte values 0..255, stored as a bitmap.
struct CharSet
{
    private ulong[4] bits;

    /// Adds a single character.
    void add(ubyte c) pure nothrow @nogc @safe
    {
        bits[c >> 6] |= 1UL << (c & 63);
    }

    /// Adds every character in `lo .. hi` (inclusive).
    void addRange(ubyte lo, ubyte hi) pure nothrow @nogc @safe
    {
        foreach (c; lo .. hi + 1)
            add(cast(ubyte) c);
    }

    /// Adds all members of `other`.
    void addAll(const CharSet other) pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 4)
            bits[i] |= other.bits[i];
    }

    /// Replaces the set with its complement over 0..255.
    void invert() pure nothrow @nogc @safe
    {
        foreach (ref b; bits)
            b = ~b;
    }

    /// True if `c` is a member.
    bool has(ubyte c) const pure nothrow @nogc @safe
    {
        return ((bits[c >> 6] >> (c & 63)) & 1) != 0;
    }

    /// Set for `\d`.
    static CharSet digits() pure nothrow @nogc @safe
    {
        CharSet s;
        s.addRange('0', '9');
        return s;
    }

    /// Set for `\w`.
    static CharSet word() pure nothrow @nogc @safe
    {
        CharSet s;
        s.addRange('a', 'z');
        s.addRange('A', 'Z');
        s.addRange('0', '9');
        s.add('_');
        return s;
    }

    /// Set for `\s`.
    static CharSet space() pure nothrow @nogc @safe
    {
        CharSet s;
        foreach (c; " \t\n\r\f\v")
            s.add(cast(ubyte) c);
        return s;
    }
}

unittest
{
    CharSet s;
    assert(!s.has('a'));
    s.add('a');
    s.addRange('0', '9');
    assert(s.has('a') && s.has('5') && !s.has('b'));
    s.invert();
    assert(!s.has('a') && s.has('b') && s.has(200));
    assert(CharSet.word().has('_') && !CharSet.word().has('-'));
    assert(CharSet.space().has('\t') && CharSet.space().has(' '));
}
