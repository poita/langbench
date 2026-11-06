/// Low-level helpers for decoding the big-endian integers and varints used by
/// the SQLite file format.
module sqlitefile.bytes;

@safe:

/// Reads an unsigned big-endian 16-bit integer at `off`.
ushort readBE16(const(ubyte)[] d, size_t off) pure nothrow @nogc
{
    return cast(ushort)((d[off] << 8) | d[off + 1]);
}

/// Reads an unsigned big-endian 32-bit integer at `off`.
uint readBE32(const(ubyte)[] d, size_t off) pure nothrow @nogc
{
    return (cast(uint) d[off] << 24) | (cast(uint) d[off + 1] << 16)
        | (cast(uint) d[off + 2] << 8) | d[off + 3];
}

/// Reads an unsigned big-endian 64-bit integer at `off`.
ulong readBE64(const(ubyte)[] d, size_t off) pure nothrow @nogc
{
    return (cast(ulong) readBE32(d, off) << 32) | readBE32(d, off + 4);
}

/// Reads a signed big-endian two's-complement integer of `size` bytes
/// (1 to 8) at `off`.
long readSignedBE(const(ubyte)[] d, size_t off, size_t size) pure nothrow @nogc
{
    if (size == 0)
        return 0;
    long v = cast(byte) d[off];
    foreach (i; 1 .. size)
        v = (v << 8) | d[off + i];
    return v;
}

/// Reads a SQLite varint (1 to 9 bytes) at `pos` and advances `pos` past it.
///
/// The result is the 64-bit two's-complement interpretation, so the
/// nine-byte encoding of a negative rowid comes back negative.
long readVarint(const(ubyte)[] d, ref size_t pos) pure nothrow @nogc
{
    ulong v = 0;
    foreach (_; 0 .. 8)
    {
        immutable b = d[pos++];
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80))
            return cast(long) v;
    }
    v = (v << 8) | d[pos++];
    return cast(long) v;
}
