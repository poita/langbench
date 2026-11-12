/// An append-only, most-significant-bit-first bit accumulator.
module qrcode.bitbuffer;

/// Accumulates bits and exposes them as bytes (zero-padded at the end).
struct BitBuffer
{
    private ubyte[] bytes_;
    private size_t length_;

    /// Number of bits stored.
    size_t length() const @safe pure nothrow @nogc { return length_; }

    /// The stored bits packed into bytes; trailing unused bits are zero.
    const(ubyte)[] bytes() const @safe pure nothrow @nogc { return bytes_; }

    /// Appends the low `count` bits of `value`, most significant first.
    void append(uint value, int count) @safe pure nothrow
    in (count >= 0 && count <= 32)
    {
        foreach_reverse (i; 0 .. count)
        {
            if ((length_ & 7) == 0)
                bytes_ ~= 0;
            if ((value >> i) & 1)
                bytes_[$ - 1] |= cast(ubyte)(0x80 >> (length_ & 7));
            length_++;
        }
    }

    /// Appends `count` zero bits.
    void appendZeros(size_t count) @safe pure nothrow
    {
        foreach (_; 0 .. count)
            append(0, 1);
    }
}

@safe pure nothrow unittest
{
    BitBuffer b;
    b.append(0b101, 3);
    b.append(0xFF, 8);
    assert(b.length == 11);
    assert(b.bytes == [0b10111111, 0b11100000]);
    b.appendZeros(5);
    assert(b.length == 16 && b.bytes.length == 2);
}
