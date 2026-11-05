/// A growable byte buffer used by the serializer and the CLI.
module jq.buffer;

/// Append-only text buffer that is cleared and reused between results.
struct Buf
{
    char[] data;
    size_t len;

    /// Make room for `extra` more bytes.
    void reserve(size_t extra) pure nothrow @trusted
    {
        if (len + extra > data.length)
        {
            size_t nc = data.length < 256 ? 256 : data.length * 2;
            while (nc < len + extra)
                nc *= 2;
            auto nd = new char[nc];
            nd[0 .. len] = data[0 .. len];
            data = nd;
        }
    }

    /// Append one byte.
    void put(char c) pure nothrow @trusted
    {
        if (len == data.length)
            reserve(1);
        data[len++] = c;
    }

    /// Append a run of bytes.
    void put(const(char)[] s) pure nothrow @trusted
    {
        reserve(s.length);
        data[len .. len + s.length] = s[];
        len += s.length;
    }

    /// The accumulated bytes (valid until the next mutation).
    @property const(char)[] slice() const pure nothrow @nogc @trusted
    {
        return data[0 .. len];
    }

    /// Forget the contents but keep the storage.
    void clear() pure nothrow @nogc @safe
    {
        len = 0;
    }
}
