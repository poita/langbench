/// A set of characters stored as a 256-entry membership table.
module regex.charset;

/// Membership table over byte values. Matching is a single table lookup.
struct CharSet
{
    /// `table[c]` is non-zero when `c` is a member.
    ubyte[256] table;

    /// A set holding exactly `c`.
    static CharSet single(ubyte c) @safe pure nothrow @nogc
    {
        CharSet s;
        s.table[c] = 1;
        return s;
    }

    /// The set of all 256 byte values.
    static CharSet all() @safe pure nothrow @nogc
    {
        CharSet s;
        s.table[] = 1;
        return s;
    }

    /// Whether `c` is a member.
    bool contains(ubyte c) const @safe pure nothrow @nogc
    {
        return table[c] != 0;
    }

    /// Add one character.
    void add(ubyte c) @safe pure nothrow @nogc
    {
        table[c] = 1;
    }

    /// Add the inclusive range `lo .. hi`.
    void addRange(ubyte lo, ubyte hi) @safe pure nothrow @nogc
    {
        foreach (c; lo .. hi + 1)
            table[c] = 1;
    }

    /// Add every member of `other`.
    void unite(const CharSet other) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. 256)
            table[i] |= other.table[i];
    }

    /// Replace the set with its complement (over all 256 byte values).
    void invert() @safe pure nothrow @nogc
    {
        foreach (ref t; table)
            t = t ? 0 : 1;
    }

    /// Whether every byte value is a member.
    bool isFull() const @safe pure nothrow @nogc
    {
        foreach (t; table)
            if (!t)
                return false;
        return true;
    }

    /// `\d`
    static CharSet digits() @safe pure nothrow @nogc
    {
        CharSet s;
        s.addRange('0', '9');
        return s;
    }

    /// `\w`
    static CharSet word() @safe pure nothrow @nogc
    {
        CharSet s;
        s.addRange('A', 'Z');
        s.addRange('a', 'z');
        s.addRange('0', '9');
        s.add('_');
        return s;
    }

    /// `\s`: space, tab, newline, carriage return, form feed, vertical tab.
    static CharSet space() @safe pure nothrow @nogc
    {
        CharSet s;
        foreach (c; " \t\n\r\f\v")
            s.add(cast(ubyte) c);
        return s;
    }
}
