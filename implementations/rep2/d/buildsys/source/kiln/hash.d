/**
 * 64-bit FNV-1a content hashing.
 */
module kiln.hash;

/// The FNV-1a 64-bit hash of `data`.
ulong fnv1a(const(char)[] data) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (b; data)
    {
        h ^= cast(ubyte) b;
        h *= 0x100000001b3UL;
    }
    return h;
}

/// Formats `h` as exactly sixteen lowercase hexadecimal digits.
string hex16(ulong h) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[16] buf;
    foreach_reverse (i; 0 .. 16)
    {
        buf[i] = digits[h & 0xf];
        h >>= 4;
    }
    return buf[].idup;
}

/**
 * Parses sixteen lowercase hex digits. Returns false (leaving `h` untouched)
 * for anything else.
 */
bool parseHex16(const(char)[] s, out ulong h) @safe pure nothrow @nogc
{
    if (s.length != 16)
        return false;
    ulong v = 0;
    foreach (c; s)
    {
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else
            return false;
        v = (v << 4) | d;
    }
    h = v;
    return true;
}

@safe pure unittest
{
    assert(hex16(fnv1a("")) == "cbf29ce484222325");
    assert(hex16(fnv1a("hello\n")) == "a9bc80cca21f28b3");
    assert(hex16(fnv1a("abc\n")) == "fc17b183ee074373");
    ulong h;
    assert(parseHex16("a9bc80cca21f28b3", h) && h == fnv1a("hello\n"));
    assert(!parseHex16("A9bc80cca21f28b3", h));
    assert(!parseHex16("a9bc80cca21f28b", h));
}
