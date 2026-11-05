/// A growable byte buffer used to assemble output without per-item allocation.
module mime.buffer;

/// Append-only byte buffer. Doubles its capacity when full.
struct ByteBuffer
{
    private ubyte[] store;
    private size_t used;

    /// Creates a buffer with `capacity` bytes reserved.
    this(size_t capacity) @safe pure nothrow
    {
        store = new ubyte[](capacity);
    }

    /// Number of bytes written so far.
    size_t length() const @safe pure nothrow @nogc
    {
        return used;
    }

    /// The bytes written so far (valid until the next append).
    inout(ubyte)[] data() inout @safe pure nothrow @nogc
    {
        return store[0 .. used];
    }

    /// Discards the contents but keeps the storage.
    void clear() @safe pure nothrow @nogc
    {
        used = 0;
    }

    /// Ensures room for `extra` more bytes.
    void reserve(size_t extra) @safe pure nothrow
    {
        immutable need = used + extra;
        if (need <= store.length)
            return;
        size_t cap = store.length < 64 ? 64 : store.length;
        while (cap < need)
            cap *= 2;
        auto n = new ubyte[](cap);
        n[0 .. used] = store[0 .. used];
        store = n;
    }

    /// Appends one byte.
    void put(ubyte b) @safe pure nothrow
    {
        reserve(1);
        store[used++] = b;
    }

    /// Appends one ASCII character.
    void put(char c) @safe pure nothrow
    {
        put(cast(ubyte) c);
    }

    /// Appends raw bytes.
    void put(scope const(ubyte)[] bytes) @safe pure nothrow
    {
        reserve(bytes.length);
        store[used .. used + bytes.length] = bytes[];
        used += bytes.length;
    }

    /// Appends the UTF-8 code units of a string.
    void put(scope const(char)[] s) @trusted pure nothrow
    {
        put(cast(const(ubyte)[]) s);
    }

    /// Appends an unsigned decimal number, zero-padded to at least `width` digits.
    void putUint(ulong v, uint width = 0) @safe pure nothrow
    {
        char[20] tmp = void;
        size_t n = 0;
        do
        {
            tmp[$ - 1 - n] = cast(char)('0' + v % 10);
            v /= 10;
            n++;
        }
        while (v != 0);
        foreach (_; n .. width)
            put('0');
        put(tmp[$ - n .. $]);
    }

    /// Appends a signed decimal number.
    void putInt(long v) @safe pure nothrow
    {
        if (v < 0)
        {
            put('-');
            putUint(cast(ulong)(-(v + 1)) + 1);
        }
        else
            putUint(cast(ulong) v);
    }

    /// Appends `v` as exactly eight lower-case hexadecimal digits.
    void putHex32(uint v) @safe pure nothrow
    {
        static immutable digits = "0123456789abcdef";
        char[8] tmp = void;
        foreach (i; 0 .. 8)
            tmp[i] = digits[(v >> (28 - 4 * i)) & 15];
        put(tmp[]);
    }

    /// Returns a copy of the contents as a string.
    string toString() const @trusted pure nothrow
    {
        return cast(string) store[0 .. used].idup;
    }
}
