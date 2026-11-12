/**
 * Character sets over the ASCII range, stored as a 256-bit bitmap.
 */
module regex.charset;

/// A set of byte values (0..255) with constant-time membership tests.
struct CharSet
{
    private ulong[4] bits;

    /// Adds the single byte `c` to the set.
    void add(ubyte c) pure nothrow @nogc @safe
    {
        bits[c >> 6] |= 1UL << (c & 63);
    }

    /// Adds every byte in the inclusive range `lo .. hi`.
    void addRange(ubyte lo, ubyte hi) pure nothrow @nogc @safe
    {
        foreach (int c; lo .. hi + 1)
            add(cast(ubyte) c);
    }

    /// Adds all members of `other`.
    void addSet(in CharSet other) pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 4)
            bits[i] |= other.bits[i];
    }

    /// True when `c` is a member.
    bool contains(ubyte c) const pure nothrow @nogc @safe
    {
        return (bits[c >> 6] >> (c & 63)) & 1;
    }

    /// Complement with respect to the ASCII range 0..127.
    CharSet negated() const pure nothrow @nogc @safe
    {
        CharSet r;
        foreach (c; 0 .. 128)
            if (!contains(cast(ubyte) c))
                r.add(cast(ubyte) c);
        return r;
    }

    /// True when no byte is a member.
    bool empty() const pure nothrow @nogc @safe
    {
        return (bits[0] | bits[1] | bits[2] | bits[3]) == 0;
    }

    /// Fills `table` so that `table[c]` is true exactly for the members.
    void toTable(ref bool[256] table) const pure nothrow @nogc @safe
    {
        foreach (c; 0 .. 256)
            table[c] = contains(cast(ubyte) c);
    }

    /// The set containing only `c`.
    static CharSet of(ubyte c) pure nothrow @nogc @safe
    {
        CharSet r;
        r.add(c);
        return r;
    }

    /// The set of all 256 byte values.
    static CharSet all() pure nothrow @nogc @safe
    {
        CharSet r;
        r.bits[] = ulong.max;
        return r;
    }

    /// `\d`
    static CharSet digits() pure nothrow @nogc @safe
    {
        CharSet r;
        r.addRange('0', '9');
        return r;
    }

    /// `\w`
    static CharSet word() pure nothrow @nogc @safe
    {
        CharSet r;
        r.addRange('0', '9');
        r.addRange('a', 'z');
        r.addRange('A', 'Z');
        r.add('_');
        return r;
    }

    /// `\s`
    static CharSet space() pure nothrow @nogc @safe
    {
        CharSet r;
        foreach (c; " \t\n\r\f\v")
            r.add(cast(ubyte) c);
        return r;
    }
}

unittest
{
    auto d = CharSet.digits();
    assert(d.contains('0') && d.contains('9') && !d.contains('a'));
    auto nd = d.negated();
    assert(!nd.contains('5') && nd.contains('x') && !nd.contains(200));
    assert(CharSet.word().contains('_') && !CharSet.word().contains('-'));
    assert(CharSet.space().contains(' ') && CharSet.space().contains('\t'));
    CharSet e;
    assert(e.empty);
    e.addRange('a', 'c');
    assert(!e.empty && e.contains('b') && !e.contains('d'));
    assert(CharSet.all().contains(255));
}
