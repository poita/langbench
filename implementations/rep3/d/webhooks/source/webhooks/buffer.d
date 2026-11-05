/**
 * Byte-oriented helpers shared by every module: the `Bytes` view type and a
 * simple growable output buffer.
 *
 * All text handled by this library is ASCII-only in its grammar, so the code
 * works on raw bytes (`const(ubyte)[]`) rather than `string`; that avoids any
 * UTF-8 decoding and lets arbitrary binary payloads pass through untouched.
 */
module webhooks.buffer;

/// A read-only view of bytes. Used for every input field and payload.
alias Bytes = const(ubyte)[];

/// Reinterpret a string literal (or any string) as a byte view without copying.
Bytes asBytes(return scope string s) @trusted pure nothrow @nogc
{
    return cast(Bytes) s;
}

/// True when `a` holds exactly the bytes of `b`.
bool equalsString(Bytes a, string b) @safe pure nothrow @nogc
{
    return a == asBytes(b);
}

/**
 * A growable byte buffer with amortised O(1) appends.
 *
 * The whole program output (and e.g. the signature headers of a simulation)
 * is accumulated in one of these, so no per-line temporaries are created.
 */
struct OutBuffer
{
    private ubyte[] store;
    private size_t used;

    /// Make room for at least `extra` more bytes.
    void reserve(size_t extra) @safe pure nothrow
    {
        immutable need = used + extra;
        if (need <= store.length)
            return;
        size_t cap = store.length < 256 ? 256 : store.length * 2;
        while (cap < need)
            cap *= 2;
        auto fresh = new ubyte[cap];
        fresh[0 .. used] = store[0 .. used];
        store = fresh;
    }

    /// Append raw bytes.
    void put(Bytes data) @safe pure nothrow
    {
        reserve(data.length);
        store[used .. used + data.length] = data[];
        used += data.length;
    }

    /// Append the bytes of a string.
    void put(string s) @safe pure nothrow
    {
        put(asBytes(s));
    }

    /// Append one byte.
    void put(ubyte b) @safe pure nothrow
    {
        reserve(1);
        store[used++] = b;
    }

    /// Append the decimal representation of `value`.
    void putInt(long value) @safe pure nothrow
    {
        ulong v = value < 0 ? 0UL - cast(ulong) value : cast(ulong) value;
        ubyte[20] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(ubyte)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        if (value < 0)
            put(cast(ubyte) '-');
        put(tmp[i .. $]);
    }

    /// The bytes written so far (valid until the next append).
    Bytes data() const @safe pure nothrow @nogc
    {
        return store[0 .. used];
    }

    /// Number of bytes written.
    size_t length() const @safe pure nothrow @nogc
    {
        return used;
    }

    /// Forget the contents, keeping the allocation.
    void clear() @safe pure nothrow @nogc
    {
        used = 0;
    }

    /// Copy the contents into a `string` (convenient for tests and callers).
    string toString() const @trusted pure nothrow
    {
        return cast(string) store[0 .. used].idup;
    }
}
