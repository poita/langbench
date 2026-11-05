/// Object ids: 20-byte SHA-1 values and their hexadecimal form.
module gitrepo.oid;

import gitrepo.errors;

/// A 20-byte object id. Usable as an associative-array key and ordered bytewise.
struct ObjectId
{
    /// The raw digest.
    ubyte[20] bytes;

    ///
    size_t toHash() const @safe pure nothrow @nogc
    {
        size_t h = 0;
        foreach (i; 0 .. size_t.sizeof)
            h = (h << 8) | bytes[i];
        return h;
    }

    ///
    bool opEquals(ref const ObjectId o) const @safe pure nothrow @nogc
    {
        return bytes == o.bytes;
    }

    ///
    int opCmp(ref const ObjectId o) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. 20)
        {
            if (bytes[i] != o.bytes[i])
                return bytes[i] < o.bytes[i] ? -1 : 1;
        }
        return 0;
    }

    /// 40 lowercase hexadecimal digits.
    string toString() const @safe pure nothrow
    {
        char[40] buf;
        foreach (i, b; bytes)
        {
            buf[2 * i] = hexDigits[b >> 4];
            buf[2 * i + 1] = hexDigits[b & 15];
        }
        return buf[].idup;
    }

    /// Parses exactly 40 hexadecimal digits (either case); throws `GitError` otherwise.
    static ObjectId fromHex(const(char)[] hex) @safe pure
    {
        ObjectId id;
        if (!tryParse(hex, id, false))
            throw new GitError("invalid object id");
        return id;
    }

    /// Parses exactly 40 hex digits into `id`. When `lowerOnly` is set, upper case digits are rejected.
    static bool tryParse(const(char)[] hex, out ObjectId id, bool lowerOnly = true) @safe pure nothrow @nogc
    {
        if (hex.length != 40)
            return false;
        foreach (i; 0 .. 20)
        {
            immutable hi = hexValue(hex[2 * i], lowerOnly);
            immutable lo = hexValue(hex[2 * i + 1], lowerOnly);
            if (hi < 0 || lo < 0)
                return false;
            id.bytes[i] = cast(ubyte)(hi << 4 | lo);
        }
        return true;
    }
}

/// The lowercase hexadecimal digits.
immutable string hexDigits = "0123456789abcdef";

/// Value of a hexadecimal digit, or -1. Upper case is accepted unless `lowerOnly`.
int hexValue(char c, bool lowerOnly = false) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (!lowerOnly && c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}
