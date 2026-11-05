/**
 * Wire-format primitives: varints, tags, zigzag, and the wire-type enum.
 */
module protowire.wire;

import core.bitop : bsr;

/// Protobuf wire types.
enum WireType : ubyte
{
    varint = 0,
    fixed64 = 1,
    lengthDelimited = 2,
    startGroup = 3,
    endGroup = 4,
    fixed32 = 5,
}

/// Maximum number of bytes in a varint.
enum maxVarintBytes = 10;
/// Maximum number of bytes in a tag or length-prefix varint.
enum maxTagBytes = 5;

/**
 * Read a varint of at most `maxBytes` bytes from `buf[pos .. end]`.
 *
 * Bits beyond bit 63 are discarded. On success `pos` is advanced past the
 * varint and `value` is set. Returns false (leaving `pos` alone) when the
 * varint is truncated by `end` or longer than `maxBytes`.
 */
bool readVarint(const(ubyte)* buf, ref size_t pos, size_t end,
        uint maxBytes, out ulong value) nothrow @nogc @system
{
    ulong v = 0;
    uint shift = 0;
    size_t p = pos;
    for (uint i = 0; i < maxBytes; i++)
    {
        if (p >= end)
            return false;
        const b = buf[p++];
        v |= cast(ulong)(b & 0x7f) << shift;
        if (!(b & 0x80))
        {
            pos = p;
            value = v;
            return true;
        }
        shift += 7;
    }
    return false;
}

/// Number of bytes in the minimal varint encoding of `v`.
size_t varintLength(ulong v) pure nothrow @nogc @safe
{
    return cast(size_t) bsr(v | 1) / 7 + 1;
}

/// Write the minimal varint encoding of `v` at `p`; returns the new position.
ubyte* putVarint(ubyte* p, ulong v) pure nothrow @nogc @system
{
    while (v >= 0x80)
    {
        *p++ = cast(ubyte)(v | 0x80);
        v >>= 7;
    }
    *p++ = cast(ubyte) v;
    return p;
}

/// 32-bit zigzag encoding.
uint zigzag32(int v) pure nothrow @nogc @safe
{
    return cast(uint)((v << 1) ^ (v >> 31));
}

/// 64-bit zigzag encoding.
ulong zigzag64(long v) pure nothrow @nogc @safe
{
    return cast(ulong)((v << 1) ^ (v >> 63));
}

/// Inverse of $(LREF zigzag32).
int unzigzag32(uint u) pure nothrow @nogc @safe
{
    return cast(int)((u >> 1) ^ (0u - (u & 1)));
}

/// Inverse of $(LREF zigzag64).
long unzigzag64(ulong u) pure nothrow @nogc @safe
{
    return cast(long)((u >> 1) ^ (0UL - (u & 1)));
}
