/// Big-endian integer access, byte-wise comparison and a growable byte buffer.
module tessera.bytes;

import core.stdc.string : memcmp;

/// Read an unsigned big-endian 16-bit integer at `off`.
uint getU16(const(ubyte)[] b, size_t off) pure nothrow @nogc @safe
{
    return (cast(uint) b[off] << 8) | b[off + 1];
}

/// Read an unsigned big-endian 32-bit integer at `off`.
uint getU32(const(ubyte)[] b, size_t off) pure nothrow @nogc @safe
{
    return (cast(uint) b[off] << 24) | (cast(uint) b[off + 1] << 16)
        | (cast(uint) b[off + 2] << 8) | b[off + 3];
}

/// Read an unsigned big-endian 64-bit integer at `off`.
ulong getU64(const(ubyte)[] b, size_t off) pure nothrow @nogc @safe
{
    return (cast(ulong) getU32(b, off) << 32) | getU32(b, off + 4);
}

/// Write a big-endian 16-bit integer at `off`.
void setU16(ubyte[] b, size_t off, uint v) pure nothrow @nogc @safe
{
    b[off] = cast(ubyte)(v >> 8);
    b[off + 1] = cast(ubyte) v;
}

/// Write a big-endian 32-bit integer at `off`.
void setU32(ubyte[] b, size_t off, uint v) pure nothrow @nogc @safe
{
    b[off] = cast(ubyte)(v >> 24);
    b[off + 1] = cast(ubyte)(v >> 16);
    b[off + 2] = cast(ubyte)(v >> 8);
    b[off + 3] = cast(ubyte) v;
}

/// Write a big-endian 64-bit integer at `off`.
void setU64(ubyte[] b, size_t off, ulong v) pure nothrow @nogc @safe
{
    setU32(b, off, cast(uint)(v >> 32));
    setU32(b, off + 4, cast(uint) v);
}

/// Unsigned byte-wise comparison; a proper prefix sorts first.
/// Returns a negative number, zero or a positive number.
int compareBytes(const(ubyte)[] a, const(ubyte)[] b) pure nothrow @nogc @trusted
{
    immutable n = a.length < b.length ? a.length : b.length;
    if (n)
    {
        immutable c = memcmp(a.ptr, b.ptr, n);
        if (c != 0)
            return c < 0 ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// True when `a` starts with `prefix`.
bool startsWith(const(ubyte)[] a, const(ubyte)[] prefix) pure nothrow @nogc @safe
{
    return a.length >= prefix.length && a[0 .. prefix.length] == prefix;
}

/// View a string's UTF-8 bytes.
const(ubyte)[] asBytes(const(char)[] s) pure nothrow @nogc @trusted
{
    return cast(const(ubyte)[]) s;
}

/// Copy bytes into an immutable string (no validation).
string toStr(const(ubyte)[] b) pure nothrow @trusted
{
    return cast(string) b.idup;
}

/// An amortised-append byte buffer.
struct ByteBuffer
{
    private ubyte[] storage;
    private size_t used;

    /// Number of bytes held.
    size_t length() const pure nothrow @nogc @safe { return used; }

    /// The bytes held (valid until the next append).
    inout(ubyte)[] data() inout pure nothrow @nogc @safe { return storage[0 .. used]; }

    /// Make room for `extra` more bytes.
    void reserve(size_t extra) pure nothrow @safe
    {
        immutable need = used + extra;
        if (need > storage.length)
        {
            size_t cap = storage.length < 256 ? 256 : storage.length;
            while (cap < need)
                cap *= 2;
            auto n = new ubyte[cap];
            n[0 .. used] = storage[0 .. used];
            storage = n;
        }
    }

    /// Append one byte.
    void put(ubyte b) pure nothrow @safe
    {
        reserve(1);
        storage[used++] = b;
    }

    /// Append a run of bytes.
    void put(const(ubyte)[] b) pure nothrow @safe
    {
        reserve(b.length);
        storage[used .. used + b.length] = b[];
        used += b.length;
    }

    /// Append text (its UTF-8 bytes).
    void putText(const(char)[] s) pure nothrow @trusted
    {
        put(cast(const(ubyte)[]) s);
    }

    /// Append a big-endian 16-bit integer.
    void putU16(uint v) pure nothrow @safe
    {
        reserve(2);
        setU16(storage, used, v);
        used += 2;
    }

    /// Append a big-endian 32-bit integer.
    void putU32(uint v) pure nothrow @safe
    {
        reserve(4);
        setU32(storage, used, v);
        used += 4;
    }

    /// Append a big-endian 64-bit integer.
    void putU64(ulong v) pure nothrow @safe
    {
        reserve(8);
        setU64(storage, used, v);
        used += 8;
    }

    /// Append `n` zero bytes.
    void putZeros(size_t n) pure nothrow @safe
    {
        reserve(n);
        storage[used .. used + n] = 0;
        used += n;
    }

    /// Drop everything after the first `n` bytes.
    void truncate(size_t n) pure nothrow @safe
    {
        assert(n <= used);
        used = n;
    }

    /// Forget all content (keeps the capacity).
    void clear() pure nothrow @safe { used = 0; }
}
