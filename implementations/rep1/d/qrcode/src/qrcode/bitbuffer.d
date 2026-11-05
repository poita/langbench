/// A most-significant-bit-first bit writer that packs straight into bytes.
module qrcode.bitbuffer;

/// Writes bits MSB first into a preallocated byte array.
struct BitWriter
{
    private ubyte[] buf;
    private size_t bits;

    /// Create a writer with room for `capacityBytes` bytes (zero-filled).
    this(size_t capacityBytes) @safe pure nothrow
    {
        buf = new ubyte[capacityBytes];
    }

    /// Number of bits written so far.
    size_t length() const @safe pure nothrow @nogc { return bits; }

    /// Append the low `count` bits of `value`, most significant first.
    void put(uint value, int count) @safe pure nothrow @nogc
    in (count >= 0 && count <= 32)
    in ((bits + count + 7) / 8 <= buf.length)
    {
        foreach_reverse (i; 0 .. count)
        {
            if ((value >> i) & 1)
                buf[bits >> 3] |= cast(ubyte)(0x80 >> (bits & 7));
            ++bits;
        }
    }

    /// Append `count` zero bits.
    void putZeros(size_t count) @safe pure nothrow @nogc
    in ((bits + count + 7) / 8 <= buf.length)
    {
        bits += count;
    }

    /// Pad to a byte boundary with zeros.
    void alignToByte() @safe pure nothrow @nogc
    {
        bits = (bits + 7) & ~cast(size_t) 7;
    }

    /// Append whole bytes alternating `a`, `b`, ... until `totalBytes` bytes exist.
    void padAlternating(ubyte a, ubyte b, size_t totalBytes) @safe pure nothrow @nogc
    in (bits % 8 == 0)
    {
        bool first = true;
        while (bits / 8 < totalBytes)
        {
            buf[bits >> 3] = first ? a : b;
            first = !first;
            bits += 8;
        }
    }

    /// The underlying bytes (the full capacity).
    inout(ubyte)[] bytes() inout @safe pure nothrow @nogc { return buf; }
}
