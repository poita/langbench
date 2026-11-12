/// Bounds-checked big-endian integer and varint decoding.
module sqlitefile.bytes;

import sqlitefile.errors;

@safe:

/// Throws `FormatException` unless `[off, off + len)` lies inside `data`.
void checkRange(const(ubyte)[] data, size_t off, size_t len) pure
{
    if (off > data.length || len > data.length - off)
        throw new FormatException("read past end of page or file");
}

/// Reads an unsigned big-endian 16-bit integer.
uint readU16(const(ubyte)[] data, size_t off) pure
{
    checkRange(data, off, 2);
    return (cast(uint) data[off] << 8) | data[off + 1];
}

/// Reads an unsigned big-endian 32-bit integer.
uint readU32(const(ubyte)[] data, size_t off) pure
{
    checkRange(data, off, 4);
    return (cast(uint) data[off] << 24) | (cast(uint) data[off + 1] << 16)
        | (cast(uint) data[off + 2] << 8) | data[off + 3];
}

/// Reads a big-endian two's-complement integer of `n` bytes (0 ≤ n ≤ 8).
long readSigned(const(ubyte)[] data, size_t off, size_t n) pure
{
    assert(n <= 8);
    checkRange(data, off, n);
    if (n == 0)
        return 0;
    ulong v = (data[off] & 0x80) ? ulong.max : 0; // sign extension
    foreach (b; data[off .. off + n])
        v = (v << 8) | b;
    return cast(long) v;
}

/// Reads a SQLite varint (1–9 bytes) at `off`.
///
/// Returns the number of bytes consumed; the signed 64-bit value is stored in
/// `value`.
size_t readVarint(const(ubyte)[] data, size_t off, out long value) pure
{
    checkRange(data, off, 1);
    ulong v = 0;
    foreach (i; 0 .. 8)
    {
        if (off + i >= data.length)
            throw new FormatException("truncated varint");
        const b = data[off + i];
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80))
        {
            value = cast(long) v;
            return i + 1;
        }
    }
    if (off + 8 >= data.length)
        throw new FormatException("truncated varint");
    v = (v << 8) | data[off + 8];
    value = cast(long) v;
    return 9;
}

unittest
{
    const ubyte[] d = [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0];
    assert(readU16(d, 0) == 0x1234);
    assert(readU32(d, 1) == 0x3456789a);
    assert(readU32(d, 0) == 0x12345678);
    assert(readSigned(d, 0, 0) == 0);
    assert(readSigned([cast(ubyte) 0xff], 0, 1) == -1);
    assert(readSigned([cast(ubyte) 0x7f], 0, 1) == 127);
    assert(readSigned([cast(ubyte) 0x80, 0x00, 0x00], 0, 3) == -8_388_608);
    assert(readSigned([cast(ubyte) 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe], 0, 6) == -2);
    assert(readSigned(d, 0, 8) == 0x123456789abcdef0);
}

unittest
{
    long v;
    assert(readVarint([cast(ubyte) 0x7f], 0, v) == 1 && v == 127);
    assert(readVarint([cast(ubyte) 0x81, 0x00], 0, v) == 2 && v == 128);
    assert(readVarint([cast(ubyte) 0xff, 0x7f], 0, v) == 2 && v == 16383);
    // Nine-byte form: the last byte contributes all eight bits.
    ubyte[9] neg = 0xff;
    assert(readVarint(neg[], 0, v) == 9 && v == -1);
    ubyte[9] min = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00];
    assert(readVarint(min[], 0, v) == 9 && v == 0);
    // 56 one-bits followed by a full 0x00 byte is 2^64 - 256.
    ubyte[9] big = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00];
    assert(readVarint(big[], 0, v) == 9 && v == -256);
    import std.exception : assertThrown;

    assertThrown!FormatException(readVarint([cast(ubyte) 0x80], 0, v));
}
