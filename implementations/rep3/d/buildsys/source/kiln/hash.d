/// Content hashing: 64-bit FNV-1a.
module kiln.hash;

/// FNV-1a 64-bit hash of a byte string.
ulong fnv1a(const(char)[] data) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (c; data)
    {
        h ^= cast(ubyte) c;
        h *= 0x100000001b3UL;
    }
    return h;
}

/// Sixteen lowercase hexadecimal digits, zero padded.
string hex16(ulong h) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[16] buf;
    foreach (i; 0 .. 16)
        buf[15 - i] = digits[(h >> (4 * i)) & 0xf];
    return buf.idup;
}

/// `hex16(fnv1a(data))`.
string hashHex(const(char)[] data) @safe pure nothrow
{
    return hex16(fnv1a(data));
}
