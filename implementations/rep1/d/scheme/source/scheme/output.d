/// The output buffer all program output is appended to.
module scheme.output;

/// A growable character buffer.
final class Output
{
    private char[] buf;
    private size_t len;

    /// Append one character.
    void put(char c)
    {
        if (len == buf.length)
            grow(1);
        buf[len++] = c;
    }

    /// Append a string.
    void put(const(char)[] s)
    {
        if (len + s.length > buf.length)
            grow(s.length);
        buf[len .. len + s.length] = s[];
        len += s.length;
    }

    /// Everything written so far.
    const(char)[] data() const { return buf[0 .. len]; }

    private void grow(size_t extra)
    {
        size_t n = buf.length * 2;
        if (n < len + extra)
            n = len + extra;
        if (n < 4096)
            n = 4096;
        buf.length = n;
    }
}
