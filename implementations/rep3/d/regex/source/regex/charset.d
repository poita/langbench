/// A set of byte values, stored as a 256-bit bitmap.
module regex.charset;

/// Set of the byte values 0..255.
struct CharSet
{
    ulong[4] bits;

    /// The set containing every byte value.
    static CharSet full() pure nothrow @nogc @safe
    {
        CharSet s;
        s.bits[] = ulong.max;
        return s;
    }

    /// Adds one byte.
    void add(ubyte c) pure nothrow @nogc @safe
    {
        bits[c >> 6] |= 1UL << (c & 63);
    }

    /// Adds every byte in `lo .. hi` inclusive.
    void addRange(ubyte lo, ubyte hi) pure nothrow @nogc @safe
    {
        foreach (int c; lo .. hi + 1)
            add(cast(ubyte) c);
    }

    /// Adds every member of `other`.
    void addSet(const CharSet other) pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 4)
            bits[i] |= other.bits[i];
    }

    /// Replaces the set with its complement (over all 256 byte values).
    void negate() pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 4)
            bits[i] = ~bits[i];
    }

    /// Membership test.
    bool has(ubyte c) const pure nothrow @nogc @safe
    {
        return ((bits[c >> 6] >> (c & 63)) & 1) != 0;
    }

    /// True if every byte value is a member.
    bool isFull() const pure nothrow @nogc @safe
    {
        return bits[0] == ulong.max && bits[1] == ulong.max
            && bits[2] == ulong.max && bits[3] == ulong.max;
    }

    /// Number of members.
    size_t count() const pure nothrow @nogc @safe
    {
        size_t n;
        foreach (c; 0 .. 256)
            if (has(cast(ubyte) c))
                ++n;
        return n;
    }

    /// `\d`: ASCII digits.
    static CharSet digits() pure nothrow @nogc @safe
    {
        CharSet s;
        s.addRange('0', '9');
        return s;
    }

    /// `\w`: ASCII letters, digits and underscore.
    static CharSet word() pure nothrow @nogc @safe
    {
        CharSet s;
        s.addRange('a', 'z');
        s.addRange('A', 'Z');
        s.addRange('0', '9');
        s.add('_');
        return s;
    }

    /// `\s`: space, tab, newline, carriage return, form feed, vertical tab.
    static CharSet space() pure nothrow @nogc @safe
    {
        CharSet s;
        foreach (c; " \t\n\r\f\v")
            s.add(cast(ubyte) c);
        return s;
    }

    /// Fills a 256-entry membership table (1 = member).
    void toTable(ref ubyte[256] table) const pure nothrow @nogc @safe
    {
        foreach (c; 0 .. 256)
            table[c] = has(cast(ubyte) c) ? 1 : 0;
    }
}
