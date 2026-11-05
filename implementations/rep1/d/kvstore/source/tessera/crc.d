/// CRC-32 (reflected polynomial 0xEDB88320), table driven.
module tessera.crc;

private uint[256] makeTable() pure nothrow @safe
{
    uint[256] t;
    foreach (i; 0 .. 256)
    {
        uint c = cast(uint) i;
        foreach (_; 0 .. 8)
            c = (c & 1) ? (c >> 1) ^ 0xEDB8_8320 : c >> 1;
        t[i] = c;
    }
    return t;
}

private static immutable uint[256] table = makeTable();

/// Incremental CRC-32 computation.
struct Crc32
{
    private uint state = 0xFFFF_FFFF;

    /// Feed more bytes.
    void put(const(ubyte)[] data) pure nothrow @nogc @safe
    {
        uint c = state;
        foreach (b; data)
            c = table[(c ^ b) & 0xFF] ^ (c >> 8);
        state = c;
    }

    /// The checksum of everything fed so far.
    uint value() const pure nothrow @nogc @safe { return state ^ 0xFFFF_FFFF; }
}

/// CRC-32 of a complete byte string.
uint crc32(const(ubyte)[] data) pure nothrow @nogc @safe
{
    Crc32 c;
    c.put(data);
    return c.value;
}
