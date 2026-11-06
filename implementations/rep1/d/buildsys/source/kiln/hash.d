/// 64-bit FNV-1a content hashing and its hexadecimal rendering.
module kiln.hash;

/// FNV-1a 64-bit hash of a byte string.
ulong fnv1a(const(char)[] data) pure nothrow @nogc @safe
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (i; 0 .. data.length)
    {
        h ^= cast(ubyte) data[i];
        h *= 0x100000001b3UL;
    }
    return h;
}

/// Renders a hash as exactly 16 lowercase hexadecimal digits.
string toHex16(ulong h) pure nothrow @safe
{
    static immutable digits = "0123456789abcdef";
    char[16] buf;
    foreach_reverse (i; 0 .. 16)
    {
        buf[i] = digits[cast(size_t)(h & 0xf)];
        h >>= 4;
    }
    return buf[].idup;
}

/// Parses exactly 16 lowercase hex digits. Returns false for anything else.
bool parseHex16(const(char)[] s, out ulong value) pure nothrow @nogc @safe
{
    value = 0;
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
    value = v;
    return true;
}
