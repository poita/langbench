/// Byte-indexed character sets used for classes and set escapes.
module regexvm.charset;

/// A set of byte values, stored as a 256-entry membership table so that a
/// membership test is a single indexed load.
struct CharSet
{
    /// `table[c]` is true iff byte `c` is a member.
    bool[256] table;

    /// Adds a single byte.
    void add(ubyte c) pure nothrow @nogc @safe { table[c] = true; }

    /// Adds every byte in the inclusive range `lo .. hi`.
    void addRange(ubyte lo, ubyte hi) pure nothrow @nogc @safe
    {
        foreach (c; lo .. hi + 1)
            table[c] = true;
    }

    /// Adds every member of `other`.
    void addSet(const CharSet other) pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 256)
            if (other.table[i])
                table[i] = true;
    }

    /// Replaces the set with its complement over all 256 byte values.
    void negate() pure nothrow @nogc @safe
    {
        foreach (ref b; table)
            b = !b;
    }

    /// True iff `c` is a member.
    bool contains(ubyte c) const pure nothrow @nogc @safe { return table[c]; }

    /// Number of members.
    size_t count() const pure nothrow @nogc @safe
    {
        size_t n;
        foreach (b; table)
            n += b;
        return n;
    }

    /// True iff every byte value is a member.
    bool isFull() const pure nothrow @nogc @safe { return count == 256; }

    /// True iff no byte value is a member.
    bool isEmpty() const pure nothrow @nogc @safe { return count == 0; }

    /// The set of a single byte.
    static CharSet of(ubyte c) pure nothrow @nogc @safe
    {
        CharSet s;
        s.add(c);
        return s;
    }

    /// Every byte value.
    static CharSet all() pure nothrow @nogc @safe
    {
        CharSet s;
        s.table[] = true;
        return s;
    }

    /// `\d`: ASCII digits.
    static CharSet digit() pure nothrow @nogc @safe
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

    /// Set for one of the escape letters `d D w W s S`; returns false if
    /// `letter` is not one of them.
    static bool forEscape(char letter, out CharSet result) pure nothrow @nogc @safe
    {
        switch (letter)
        {
        case 'd': result = digit(); return true;
        case 'w': result = word(); return true;
        case 's': result = space(); return true;
        case 'D': result = digit(); result.negate(); return true;
        case 'W': result = word(); result.negate(); return true;
        case 'S': result = space(); result.negate(); return true;
        default: return false;
        }
    }
}
