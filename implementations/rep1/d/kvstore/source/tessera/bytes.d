/// Big-endian integer access and byte-string comparison helpers.
module tessera.bytes;

/// Read an unsigned big-endian 16-bit integer at `off`.
uint getU16(const(ubyte)[] b, size_t off) @safe pure nothrow @nogc
{
    return (cast(uint) b[off] << 8) | b[off + 1];
}

/// Read an unsigned big-endian 32-bit integer at `off`.
uint getU32(const(ubyte)[] b, size_t off) @safe pure nothrow @nogc
{
    return (cast(uint) b[off] << 24) | (cast(uint) b[off + 1] << 16)
        | (cast(uint) b[off + 2] << 8) | b[off + 3];
}

/// Read an unsigned big-endian 64-bit integer at `off`.
ulong getU64(const(ubyte)[] b, size_t off) @safe pure nothrow @nogc
{
    return (cast(ulong) getU32(b, off) << 32) | getU32(b, off + 4);
}

/// Write an unsigned big-endian 16-bit integer at `off`.
void putU16(ubyte[] b, size_t off, uint v) @safe pure nothrow @nogc
{
    b[off] = cast(ubyte)(v >> 8);
    b[off + 1] = cast(ubyte) v;
}

/// Write an unsigned big-endian 32-bit integer at `off`.
void putU32(ubyte[] b, size_t off, uint v) @safe pure nothrow @nogc
{
    b[off] = cast(ubyte)(v >> 24);
    b[off + 1] = cast(ubyte)(v >> 16);
    b[off + 2] = cast(ubyte)(v >> 8);
    b[off + 3] = cast(ubyte) v;
}

/// Write an unsigned big-endian 64-bit integer at `off`.
void putU64(ubyte[] b, size_t off, ulong v) @safe pure nothrow @nogc
{
    putU32(b, off, cast(uint)(v >> 32));
    putU32(b, off + 4, cast(uint) v);
}

/// Unsigned byte-wise comparison; a proper prefix sorts first (SPEC §5.1).
/// Returns a negative number, zero or a positive number.
int compareBytes(const(ubyte)[] a, const(ubyte)[] b) @safe pure nothrow @nogc
{
    immutable n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    if (a.length == b.length)
        return 0;
    return a.length < b.length ? -1 : 1;
}

/// True when `a` begins with `prefix`.
bool hasPrefix(const(ubyte)[] a, const(ubyte)[] prefix) @safe pure nothrow @nogc
{
    return a.length >= prefix.length && a[0 .. prefix.length] == prefix;
}

/// View a string's UTF-8 bytes.
const(ubyte)[] asBytes(const(char)[] s) @trusted pure nothrow @nogc
{
    return cast(const(ubyte)[]) s;
}

@safe pure nothrow unittest
{
    ubyte[8] b;
    putU64(b[], 0, 0x0102030405060708UL);
    assert(b == [1, 2, 3, 4, 5, 6, 7, 8]);
    assert(getU64(b[], 0) == 0x0102030405060708UL);
    assert(getU32(b[], 4) == 0x05060708);
    assert(getU16(b[], 6) == 0x0708);
    assert(compareBytes([1, 2], [1, 2, 0]) < 0);
    assert(compareBytes([2], [1, 9, 9]) > 0);
    assert(compareBytes([0x80], [0x7f]) > 0);
    assert(compareBytes([], []) == 0);
    assert(hasPrefix([1, 2, 3], [1, 2]));
    assert(!hasPrefix([1], [1, 2]));
}
