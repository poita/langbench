/// Output buffer and result formatting.
module regexvm.output;

import regexvm.regex : Match;

/// A growing byte buffer with hand-written decimal formatting; results are
/// appended and the whole buffer is written once at the end.
struct OutputBuffer
{
    private ubyte[] buf;
    private size_t len;

    /// The bytes appended so far.
    const(ubyte)[] data() const pure nothrow @nogc @safe { return buf[0 .. len]; }

    private void reserve(size_t extra) pure nothrow @safe
    {
        if (len + extra > buf.length)
        {
            size_t cap = buf.length ? buf.length * 2 : 4096;
            while (cap < len + extra)
                cap *= 2;
            buf.length = cap;
        }
    }

    /// Appends one byte.
    void putChar(char c) pure nothrow @safe
    {
        reserve(1);
        buf[len++] = c;
    }

    /// Appends `v` in plain decimal.
    void putNumber(size_t v) pure nothrow @safe
    {
        reserve(20);
        ubyte[20] tmp;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(ubyte)('0' + v % 10);
            v /= 10;
        }
        while (v);
        const k = tmp.length - i;
        buf[len .. len + k] = tmp[i .. $];
        len += k;
    }

    /// Appends a string literal.
    void put(const(char)[] s) pure nothrow @trusted
    {
        reserve(s.length);
        buf[len .. len + s.length] = cast(const(ubyte)[]) s;
        len += s.length;
    }

    /// Appends one result line in the documented format:
    /// `no`, or `match <start> <end>` followed by `|<gs>,<ge>` / `|-`
    /// per group, then `\n`.
    void putResult(const Match m) pure nothrow @safe
    {
        if (!m.matched)
        {
            put("no\n");
            return;
        }
        put("match ");
        putNumber(m.begin);
        putChar(' ');
        putNumber(m.end);
        foreach (ref g; m.groups)
        {
            putChar('|');
            if (g.isSet)
            {
                putNumber(g.begin);
                putChar(',');
                putNumber(g.end);
            }
            else
                putChar('-');
        }
        putChar('\n');
    }
}
