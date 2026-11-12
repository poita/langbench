/**
 * 64-bit FNV-1a content hashing.
 *
 * Every content hash in Kiln is an FNV-1a/64 digest rendered as exactly sixteen
 * lowercase hexadecimal digits.
 */
module kiln.hash;

/// FNV-1a 64-bit offset basis.
enum ulong fnvOffsetBasis = 0xcbf29ce484222325UL;
/// FNV-1a 64-bit prime.
enum ulong fnvPrime = 0x100000001b3UL;

/// Hashes the bytes of `data` (strings are treated as raw bytes, never decoded).
ulong fnv1a(const(char)[] data) @safe pure nothrow @nogc
{
    ulong h = fnvOffsetBasis;
    foreach (char c; data)
    {
        h ^= cast(ubyte) c;
        h *= fnvPrime;
    }
    return h;
}

/// Renders `h` as sixteen lowercase hexadecimal digits.
string toHex16(ulong h) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[16] buf;
    foreach_reverse (i; 0 .. 16)
    {
        buf[i] = digits[cast(size_t)(h & 0xf)];
        h >>= 4;
    }
    return buf.idup;
}

/// Parses exactly sixteen lowercase hexadecimal digits.
bool parseHex16(const(char)[] s, out ulong value) @safe pure nothrow @nogc
{
    if (s.length != 16)
        return false;
    ulong v = 0;
    foreach (char c; s)
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
    value = v;
    return true;
}

unittest
{
    assert(toHex16(fnv1a("")) == "cbf29ce484222325");
    assert(toHex16(fnv1a("hello\n")) == "a9bc80cca21f28b3");
    assert(toHex16(fnv1a("abc\n")) == "fc17b183ee074373");
}

unittest
{
    ulong v;
    assert(parseHex16("a9bc80cca21f28b3", v) && v == fnv1a("hello\n"));
    assert(!parseHex16("A9bc80cca21f28b3", v));
    assert(!parseHex16("a9bc80cca21f28b", v));
    assert(toHex16(0) == "0000000000000000");
}
