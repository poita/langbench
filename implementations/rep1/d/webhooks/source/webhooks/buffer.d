/**
 * A growable output byte buffer.
 *
 * `ByteSink` is the single output buffer used throughout the library: Base64
 * and hex encoders, signature headers and the simulator report all append to
 * it directly, so no intermediate strings are built.
 */
module webhooks.buffer;

import std.array : uninitializedArray;

/// Append-only byte buffer with amortised O(1) growth.
struct ByteSink
{
    private ubyte[] storage;
    private size_t used;

    /// Number of bytes written so far.
    size_t length() const @safe pure nothrow @nogc { return used; }

    /// The bytes written so far (a view; invalidated by further writes).
    inout(ubyte)[] data() inout @safe pure nothrow @nogc { return storage[0 .. used]; }

    /// Discards everything after the first `newLength` bytes.
    void truncate(size_t newLength) @safe pure nothrow @nogc
    in (newLength <= used)
    {
        used = newLength;
    }

    /// Ensures room for `extra` more bytes without reallocation.
    void reserve(size_t extra) @safe pure nothrow
    {
        immutable need = used + extra;
        if (need <= storage.length)
            return;
        size_t cap = storage.length < 256 ? 256 : storage.length;
        while (cap < need)
            cap *= 2;
        auto grown = uninitializedArray!(ubyte[])(cap);
        grown[0 .. used] = storage[0 .. used];
        storage = grown;
    }

    /// Appends one byte.
    void put(ubyte b) @safe pure nothrow
    {
        reserve(1);
        storage[used++] = b;
    }

    /// Appends a character (must be ASCII).
    void putChar(char c) @safe pure nothrow
    {
        put(cast(ubyte) c);
    }

    /// Appends a byte slice.
    void put(scope const(ubyte)[] bytes) @safe pure nothrow
    {
        reserve(bytes.length);
        storage[used .. used + bytes.length] = bytes[];
        used += bytes.length;
    }

    /// Appends a string literal / ASCII text.
    void put(scope const(char)[] text) @trusted pure nothrow
    {
        put(cast(const(ubyte)[]) text);
    }

    /// Appends the decimal representation of `value`.
    void putInt(long value) @safe pure nothrow
    {
        ubyte[20] tmp;
        size_t pos = tmp.length;
        // Work with the negative magnitude so long.min is handled.
        immutable neg = value < 0;
        long v = neg ? value : -value;
        do
        {
            tmp[--pos] = cast(ubyte)('0' - v % 10);
            v /= 10;
        }
        while (v != 0);
        if (neg)
            tmp[--pos] = '-';
        put(tmp[pos .. $]);
    }
}

@safe pure nothrow unittest
{
    ByteSink s;
    s.put("ab");
    s.putInt(-12);
    assert(cast(const(char)[]) s.data == "ab-12");
}
