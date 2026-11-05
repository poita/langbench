/**
 * A minimal growable byte buffer.
 *
 * Used both for the serializer's output and as scratch space while decoding
 * string escapes. Growth is geometric, so appends are amortised O(1).
 */
module canonjson.buffer;

import std.array : uninitializedArray;

/// Growable buffer of bytes with amortised O(1) append.
struct ByteBuffer
{
    private ubyte[] store;
    private size_t used;

    /// Creates a buffer with room for `capacity` bytes before the first reallocation.
    this(size_t capacity) @safe
    {
        store = uninitializedArray!(ubyte[])(capacity);
    }

    /// Number of bytes stored.
    size_t length() const @safe pure nothrow @nogc { return used; }

    /// The stored bytes. Invalidated by any later append.
    inout(ubyte)[] data() inout @safe pure nothrow @nogc { return store[0 .. used]; }

    /// Discards the content but keeps the allocation.
    void clear() @safe pure nothrow @nogc { used = 0; }

    /// Ensures room for `extra` more bytes.
    void reserve(size_t extra) @safe
    {
        immutable need = used + extra;
        if (need <= store.length)
            return;
        size_t cap = store.length * 2;
        if (cap < need)
            cap = need;
        if (cap < 64)
            cap = 64;
        auto grown = uninitializedArray!(ubyte[])(cap);
        grown[0 .. used] = store[0 .. used];
        store = grown;
    }

    /// Appends one byte.
    void put(ubyte b) @safe
    {
        if (used == store.length)
            reserve(1);
        store[used++] = b;
    }

    /// Appends a run of bytes (bulk copy).
    void put(const(ubyte)[] bytes) @safe
    {
        reserve(bytes.length);
        store[used .. used + bytes.length] = bytes[];
        used += bytes.length;
    }

    /// Appends the ASCII characters of `text`.
    void put(string text) @trusted
    {
        put(cast(const(ubyte)[]) text);
    }
}
