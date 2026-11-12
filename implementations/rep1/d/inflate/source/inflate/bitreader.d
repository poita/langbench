/// LSB-first bit reader over an in-memory byte slice.
module inflate.bitreader;

import inflate.error;

/**
 * Reads bits starting from the least significant bit of each byte.
 *
 * A 64-bit buffer is refilled with `refill`; peeking past the end of the
 * input yields zero bits, but `consume`/`bits` refuse to consume bits that do
 * not exist and throw `InflateError.truncated`.
 */
struct BitReader
{
    private const(ubyte)[] data;
    private size_t pos; // next byte of `data` to load
    /// Bit buffer; the low `count` bits are valid (higher bits are look-ahead).
    ulong buf;
    /// Number of valid bits in `buf`.
    uint count;

    /// Start reading at the beginning of `data`.
    this(const(ubyte)[] data) @safe pure nothrow @nogc
    {
        this.data = data;
    }

    /// Top the buffer up to at least 56 bits (fewer only at end of input).
    void refill() @trusted pure nothrow @nogc
    {
        if (pos + 8 <= data.length)
        {
            import core.stdc.string : memcpy;

            ulong v = void;
            memcpy(&v, data.ptr + pos, 8);
            version (BigEndian)
            {
                import core.bitop : bswap;

                v = bswap(v);
            }
            buf |= v << count;
            pos += (63 - count) >> 3;
            count |= 56;
        }
        else
        {
            while (count <= 56 && pos < data.length)
            {
                buf |= ulong(data[pos++]) << count;
                count += 8;
            }
        }
    }

    /// Drop `n` bits (`n <= 15` after a `refill` is always safe), or throw if fewer remain.
    void consume(uint n) @safe pure
    {
        if (n > count)
            fail(InflateError.truncated, "unexpected end of stream");
        buf >>= n;
        count -= n;
    }

    /// Read an `n`-bit number, first bit read is bit 0 (`n <= 32`). Caller must have refilled.
    uint bits(uint n) @safe pure
    {
        if (n > count)
            fail(InflateError.truncated, "unexpected end of stream");
        const v = cast(uint)(buf & ((1UL << n) - 1));
        buf >>= n;
        count -= n;
        return v;
    }

    /// Refill, then read an `n`-bit number.
    uint readBits(uint n) @safe pure
    {
        refill();
        return bits(n);
    }

    /// Discard bits up to the next byte boundary.
    void alignToByte() @safe pure nothrow @nogc
    {
        const drop = count & 7;
        buf >>= drop;
        count -= drop;
    }

    /**
     * Take `n` whole bytes. The reader must be byte-aligned. Returns a slice
     * of the underlying input (not a copy).
     */
    const(ubyte)[] takeBytes(size_t n) @safe pure
    {
        assert((count & 7) == 0);
        // Hand back buffered look-ahead bytes to the input.
        pos -= count >> 3;
        buf = 0;
        count = 0;
        if (n > data.length - pos)
            fail(InflateError.truncated, "stored block extends past end of stream");
        auto r = data[pos .. pos + n];
        pos += n;
        return r;
    }

    /// True if whole bytes of the input remain unconsumed (the "trailing data" check).
    bool hasUnconsumedBytes() const @safe pure nothrow @nogc
    {
        return pos - (count >> 3) < data.length;
    }
}

@safe pure unittest
{
    ubyte[] d = [0b1011_0101, 0xff];
    auto br = BitReader(d);
    br.refill();
    assert(br.bits(1) == 1);
    assert(br.bits(3) == 0b010); // LSB first
    assert(br.bits(4) == 0b1011);
    assert(br.bits(8) == 0xff);
    assert(!br.hasUnconsumedBytes);
    import std.exception : assertThrown;

    assertThrown!InflateException(br.bits(1));
}

@safe pure unittest
{
    // Reading across many refills reproduces the input.
    ubyte[] d = new ubyte[100];
    foreach (i, ref b; d)
        b = cast(ubyte)(i * 37 + 11);
    auto br = BitReader(d);
    foreach (b; d)
        assert(br.readBits(8) == b);
    assert(!br.hasUnconsumedBytes);
}

@safe pure unittest
{
    ubyte[] d = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    auto br = BitReader(d);
    assert(br.readBits(3) == 1);
    br.alignToByte();
    assert(br.takeBytes(3) == [2, 3, 4]);
    assert(br.readBits(8) == 5);
    assert(br.hasUnconsumedBytes);
}
