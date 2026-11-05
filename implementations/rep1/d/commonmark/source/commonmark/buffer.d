/// A growable byte buffer used for output and scratch text.
module commonmark.buffer;

/// Append-only growable character buffer with geometric growth.
struct Buffer
{
    private char[] _data;
    private size_t _len;

    /// Ensure room for at least `extra` more characters.
    void reserve(size_t extra) pure nothrow
    {
        immutable need = _len + extra;
        if (need <= _data.length)
            return;
        size_t cap = _data.length < 256 ? 256 : _data.length * 2;
        while (cap < need)
            cap *= 2;
        _data.length = cap;
    }

    /// Append one character.
    void put(char c) pure nothrow
    {
        if (_len == _data.length)
            reserve(1);
        _data[_len++] = c;
    }

    /// Append a string.
    void put(const(char)[] s) pure nothrow
    {
        if (s.length == 0)
            return;
        reserve(s.length);
        _data[_len .. _len + s.length] = s[];
        _len += s.length;
    }

    /// Append a non-negative integer in decimal.
    void putDecimal(uint v) pure nothrow
    {
        char[10] tmp;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        put(tmp[i .. $]);
    }

    /// The current contents (valid until the next mutation).
    @property const(char)[] data() const pure nothrow @nogc
    {
        return _data[0 .. _len];
    }

    /// Number of characters stored.
    @property size_t length() const pure nothrow @nogc
    {
        return _len;
    }

    /// Last character; the buffer must not be empty.
    @property char back() const pure nothrow @nogc
    {
        return _data[_len - 1];
    }

    /// True if nothing has been written.
    @property bool empty() const pure nothrow @nogc
    {
        return _len == 0;
    }

    /// Discard the contents but keep the allocation.
    void clear() pure nothrow @nogc
    {
        _len = 0;
    }

    /// Copy the contents into a new immutable string.
    string idup() const pure nothrow
    {
        return _data[0 .. _len].idup;
    }
}
