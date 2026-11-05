/++
`OutBuf`: a growable byte buffer with fast, allocation-free integer
formatting, used to collect the textual event stream.
+/
module orderbook.outbuf;

/// Append-only byte buffer. Events are written here and flushed once.
struct OutBuf
{
    private ubyte[] buf;
    private size_t len;

    /// Reserve room for at least `bytes` bytes in total.
    void reserve(size_t bytes) @safe pure nothrow
    {
        if (bytes > buf.length)
            buf.length = bytes;
    }

    /// The bytes written so far.
    const(ubyte)[] data() const @safe pure nothrow @nogc
    {
        return buf[0 .. len];
    }

    /// Number of bytes written so far.
    size_t length() const @safe pure nothrow @nogc
    {
        return len;
    }

    /// Discard the contents (keeps the allocation).
    void clear() @safe pure nothrow @nogc
    {
        len = 0;
    }

    private void grow(size_t extra) @safe pure nothrow
    {
        size_t want = len + extra;
        size_t cap = buf.length < 4096 ? 4096 : buf.length;
        while (cap < want)
            cap *= 2;
        buf.length = cap;
    }

    /// Append one byte.
    void put(char c) @safe pure nothrow
    {
        if (len == buf.length)
            grow(1);
        buf[len++] = cast(ubyte) c;
    }

    /// Append a string verbatim.
    void put(scope const(char)[] s) @trusted pure nothrow
    {
        if (len + s.length > buf.length)
            grow(s.length);
        buf[len .. len + s.length] = cast(const(ubyte)[]) s;
        len += s.length;
    }

    /// Append `v` in decimal (no sign, no padding).
    void putUint(ulong v) @safe pure nothrow
    {
        if (len + 20 > buf.length)
            grow(20);
        ubyte[20] tmp = void;
        size_t i = 20;
        do
        {
            tmp[--i] = cast(ubyte)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        const n = 20 - i;
        buf[len .. len + n] = tmp[i .. 20];
        len += n;
    }

    /// Append a space followed by `v` in decimal.
    void putSpaceUint(ulong v) @safe pure nothrow
    {
        put(' ');
        putUint(v);
    }
}
