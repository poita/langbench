/// An LSB-first bit reader with a 64-bit buffer.
module inflate.bitreader;

import inflate.errors;

/**
 * Reads bits from a byte array, least significant bit of each byte first.
 *
 * The buffer holds `count` valid bits in the low end of `buffer`. Reading
 * past the end of the data is possible for *peeking* (the missing bits read
 * as zero or as further real bits, never as anything the caller may rely
 * on), but `drop`/`take` throw `InflateError.truncated` when asked to consume
 * more bits than really exist.
 */
struct BitReader
{
    private const(ubyte)[] data;
    private size_t pos;      /// next byte of `data` to load
    ulong buffer;            /// bit buffer, next bit in bit 0
    uint count;              /// number of real bits in the buffer

    ///
    this(const(ubyte)[] data) pure nothrow @nogc @safe
    {
        this.data = data;
    }

    /// Ensures at least 56 bits are buffered, or all remaining bits if fewer exist.
    void refill() pure @safe
    {
        import std.bitmanip : littleEndianToNative;

        if (pos + 8 <= data.length)
        {
            immutable ubyte[8] raw = data[pos .. pos + 8];
            buffer |= littleEndianToNative!ulong(raw) << count;
            pos += (63 - count) >> 3;
            count |= 56;
        }
        else
        {
            while (count <= 56 && pos < data.length)
            {
                buffer |= cast(ulong) data[pos++] << count;
                count += 8;
            }
        }
    }

    /// The next `n` bits (n <= 32) without consuming them; call `refill` first.
    uint peek(uint n) const pure nothrow @nogc @safe
    {
        return cast(uint)(buffer & ((1UL << n) - 1));
    }

    /// Consumes `n` bits; throws `truncated` if fewer than `n` real bits remain.
    void drop(uint n) pure @safe
    {
        if (n > count)
            throw new InflateException(InflateError.truncated);
        buffer >>= n;
        count -= n;
    }

    /// Refills if needed, then consumes and returns an `n`-bit (n <= 32) number, LSB first.
    uint take(uint n) pure @safe
    {
        if (count < n)
            refill();
        immutable v = peek(n);
        drop(n);
        return v;
    }

    /// Number of bits consumed so far.
    size_t bitPosition() const pure nothrow @nogc @safe
    {
        return pos * 8 - count;
    }

    /// Discards bits up to the next byte boundary.
    void alignToByte() pure nothrow @nogc @safe
    {
        immutable n = count & 7;
        buffer >>= n;
        count -= n;
    }

    /// Total length of the underlying data in bytes.
    size_t length() const pure nothrow @nogc @safe
    {
        return data.length;
    }

    /**
     * Returns the next `n` whole bytes of the stream and restarts the reader
     * after them. The reader must be byte aligned (see `alignToByte`).
     * Throws `truncated` if fewer than `n` bytes remain.
     */
    const(ubyte)[] takeBytes(size_t n) pure @safe
    {
        immutable start = pos - count / 8;
        if (n > data.length - start)
            throw new InflateException(InflateError.truncated);
        seekByte(start + n);
        return data[start .. start + n];
    }

    /// Empties the buffer and continues reading at byte offset `offset`.
    void seekByte(size_t offset) pure nothrow @nogc @safe
    {
        pos = offset;
        buffer = 0;
        count = 0;
    }

    /// True if the unread input, rounded up to whole bytes, is empty.
    bool atEnd() const pure nothrow @nogc @safe
    {
        return (bitPosition + 7) / 8 == data.length;
    }
}
