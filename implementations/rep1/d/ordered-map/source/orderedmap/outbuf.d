/**
 * A growable, append-only byte buffer with an inlined fast path.
 *
 * Unlike the built-in `~=` on arrays, appends here compile to a capacity check
 * and a bulk copy at the call site; there is no out-of-line runtime call unless
 * the buffer has to grow.
 */
module orderedmap.outbuf;

import orderedmap.parse : formatLong;

/// Append-only byte buffer.
struct OutBuffer
{
    private char[] buf;
    private size_t len;

    @disable this(this);

    /// Creates a buffer with `capacity` bytes pre-allocated.
    this(size_t capacity) @safe pure nothrow
    {
        buf = new char[capacity];
    }

    /// Number of bytes written so far.
    size_t length() const @safe pure nothrow @nogc
    {
        return len;
    }

    /// The bytes written so far.
    const(char)[] data() const @safe pure nothrow @nogc
    {
        return buf[0 .. len];
    }

    /// Discards the contents, keeping the allocation.
    void clear() @safe pure nothrow @nogc
    {
        len = 0;
    }

    /// Appends `s`.
    pragma(inline, true)
    void put(const(char)[] s) @trusted pure nothrow
    {
        const n = s.length;
        if (n > buf.length - len)
            grow(n);
        buf[len .. len + n] = s[];
        len += n;
    }

    /// Appends one character.
    pragma(inline, true)
    void put(char c) @trusted pure nothrow
    {
        if (len == buf.length)
            grow(1);
        buf[len++] = c;
    }

    /// Appends the canonical decimal form of `v` (no allocation).
    void put(long v) @safe pure nothrow
    {
        char[20] scratch = void;
        put(formatLong(v, scratch));
    }

    /// Appends `v` followed by a newline.
    void putLine(const(char)[] s) @safe pure nothrow
    {
        put(s);
        put('\n');
    }

private:
    void grow(size_t extra) @safe pure nothrow
    {
        size_t cap = buf.length ? buf.length : 4096;
        while (cap - len < extra)
            cap *= 2;
        buf.length = cap;
    }
}
