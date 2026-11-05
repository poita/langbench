/**
 * A growable output byte buffer.
 *
 * All of the library's rendering functions append into an `OutBuf`, so a whole
 * run produces one buffer that is written out once.
 */
module webhooks.outbuf;

/// Growable byte buffer with helpers for the formats the library prints.
struct OutBuf
{
    private ubyte[] storage;
    private size_t used;

    /// The bytes written so far.
    @property const(ubyte)[] data() const @safe pure nothrow @nogc
    {
        return storage[0 .. used];
    }

    /// Number of bytes written so far.
    @property size_t length() const @safe pure nothrow @nogc
    {
        return used;
    }

    /// Discards the contents (keeps the capacity).
    void clear() @safe pure nothrow @nogc
    {
        used = 0;
    }

    /// Appends `n` uninitialised bytes and returns the slice to fill in.
    /// The slice is invalidated by the next call that grows the buffer.
    ubyte[] extend(size_t n) @safe pure nothrow
    {
        immutable need = used + n;
        if (need > storage.length)
        {
            size_t cap = storage.length * 2;
            if (cap < need)
                cap = need;
            if (cap < 4096)
                cap = 4096;
            storage.length = cap;
        }
        auto r = storage[used .. need];
        used = need;
        return r;
    }

    /// Appends raw bytes.
    void put(scope const(ubyte)[] bytes) @safe pure nothrow
    {
        extend(bytes.length)[] = bytes[];
    }

    /// Appends the bytes of a string.
    void put(scope const(char)[] text) @trusted pure nothrow
    {
        extend(text.length)[] = cast(const(ubyte)[]) text;
    }

    /// Appends one byte.
    void putByte(ubyte b) @safe pure nothrow
    {
        extend(1)[0] = b;
    }

    /// Appends `value` in decimal.
    void putInt(long value) @safe pure nothrow
    {
        ubyte[20] tmp = void;
        size_t i = tmp.length;
        ulong mag = value < 0 ? -cast(ulong) value : cast(ulong) value;
        do
        {
            tmp[--i] = cast(ubyte)('0' + mag % 10);
            mag /= 10;
        }
        while (mag != 0);
        if (value < 0)
            tmp[--i] = '-';
        put(tmp[i .. $]);
    }

    /// Appends `bytes` as lowercase hex (nothing for an empty slice).
    void putHex(scope const(ubyte)[] bytes) @safe pure nothrow
    {
        static immutable digits = "0123456789abcdef";
        auto dst = extend(bytes.length * 2);
        foreach (i, b; bytes)
        {
            dst[2 * i] = digits[b >> 4];
            dst[2 * i + 1] = digits[b & 15];
        }
    }
}

@safe pure nothrow unittest
{
    OutBuf o;
    o.put("a");
    o.putInt(-12);
    o.putByte('!');
    assert(o.data == cast(const(ubyte)[]) "a-12!");
}
