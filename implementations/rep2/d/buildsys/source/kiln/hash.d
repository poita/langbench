/**
 * 64-bit FNV-1a content hashing and its 16-digit hexadecimal form.
 */
module kiln.hash;

/// FNV-1a offset basis.
enum ulong fnvOffset = 0xcbf29ce484222325UL;
/// FNV-1a prime.
enum ulong fnvPrime = 0x100000001b3UL;

/// Hashes a byte string with 64-bit FNV-1a.
ulong fnv1a(const(char)[] data) @safe pure nothrow @nogc
{
    ulong h = fnvOffset;
    foreach (immutable char c; data)
    {
        h ^= cast(ubyte) c;
        h *= fnvPrime;
    }
    return h;
}

/// Formats a hash as exactly 16 lowercase hex digits.
string toHex16(ulong h) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[] r = new char[16];
    foreach_reverse (i; 0 .. 16)
    {
        r[i] = digits[h & 15];
        h >>= 4;
    }
    return (() @trusted => cast(string) r)();
}

/// Parses exactly 16 lowercase hex digits. Returns false for anything else.
bool parseHex16(const(char)[] s, out ulong h) @safe pure nothrow @nogc
{
    if (s.length != 16)
        return false;
    ulong v = 0;
    foreach (immutable char c; s)
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
