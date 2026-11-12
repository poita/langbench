/// CRC-32 as specified in SPEC §3 (reflected polynomial 0xEDB88320),
/// implemented from scratch with a lookup table built at compile time.
module tessera.crc;

private uint[256] makeTable() @safe pure nothrow @nogc
{
    uint[256] t;
    foreach (n; 0 .. 256)
    {
        uint c = n;
        foreach (_; 0 .. 8)
            c = (c & 1) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
        t[n] = c;
    }
    return t;
}

private static immutable uint[256] table = makeTable();

/// Incremental CRC-32 computation.
struct Crc32
{
    private uint state = 0xFFFFFFFFu;

    /// Feed more bytes.
    void put(const(ubyte)[] data) @safe pure nothrow @nogc
    {
        uint c = state;
        foreach (b; data)
            c = table[(c ^ b) & 0xFF] ^ (c >> 8);
        state = c;
    }

    /// The checksum of everything fed so far.
    uint finish() const @safe pure nothrow @nogc
    {
        return state ^ 0xFFFFFFFFu;
    }
}

/// CRC-32 of a byte string.
uint crc32(const(ubyte)[] data) @safe pure nothrow @nogc
{
    Crc32 c;
    c.put(data);
    return c.finish();
}

@safe pure nothrow unittest
{
    import tessera.bytes : asBytes;

    assert(crc32([]) == 0);
    assert(crc32(asBytes("a")) == 0xE8B7BE43);
    assert(crc32(asBytes("123456789")) == 0xCBF43926);
    assert(crc32(asBytes("TESSERA1")) == 0x2C9A9B66);
    assert(crc32(asBytes("TESSWAL1")) == 0x7D446716);
    ubyte[20] z;
    assert(crc32(z[]) == 0x0FD59B8D);
    ubyte[1024] zz;
    assert(crc32(zz[]) == 0xEFB5AF2E);
    // incremental use agrees with one-shot use
    Crc32 c;
    c.put(asBytes("1234"));
    c.put(asBytes("56789"));
    assert(c.finish() == 0xCBF43926);
}
