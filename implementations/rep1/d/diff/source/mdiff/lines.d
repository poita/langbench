/// Zero-copy line scanning over an in-memory byte buffer.
module mdiff.lines;

import core.stdc.string : memchr;
import mdiff.errors;

/**
 * Reads lines from a buffer as views (slices) into it; nothing is copied.
 *
 * A trailing `\r` before the `\n` is dropped (CRLF tolerance) and the final
 * line may lack its `\n`. Content is only ever consumed by count, never by
 * inspecting its text.
 */
struct LineReader
{
    private const(char)[] buf;
    private size_t pos;

    /// Start reading at the beginning of `buffer`.
    this(const(char)[] buffer) @safe pure nothrow @nogc
    {
        buf = buffer;
    }

    /// True when no input remains.
    bool empty() const @safe pure nothrow @nogc
    {
        return pos >= buf.length;
    }

    /// Returns the next line (without its terminator). Throws at end of input.
    const(char)[] readLine() @trusted
    {
        if (pos >= buf.length)
            throw new FormatException("unexpected end of input");
        immutable rest = buf.length - pos;
        const(void)* hit = memchr(buf.ptr + pos, '\n', rest);
        size_t end = hit is null ? buf.length : cast(const(char)*) hit - buf.ptr;
        size_t stop = end;
        if (stop > pos && buf[stop - 1] == '\r')
            --stop;
        auto line = buf[pos .. stop];
        pos = hit is null ? end : end + 1;
        return line;
    }

    /// Reads a count line: ASCII digits, trailing spaces/tabs ignored.
    size_t readCount() @safe
    {
        auto line = readLine();
        while (line.length && (line[$ - 1] == ' ' || line[$ - 1] == '\t'))
            line = line[0 .. $ - 1];
        return parseCount(line);
    }

    /// Reads exactly `n` lines as views into the buffer.
    const(char)[][] readLines(size_t n) @safe
    {
        // n lines need at least n - 1 line terminators, so a bogus huge count
        // is rejected before it can trigger a huge allocation.
        if (n > buf.length - pos + 1)
            throw new FormatException("line count exceeds input size");
        auto result = new const(char)[][](n);
        foreach (ref l; result)
            l = readLine();
        return result;
    }

    /// Succeeds if only empty lines remain; otherwise throws.
    void expectEnd() @safe
    {
        while (!empty)
            if (readLine().length != 0)
                throw new FormatException("unexpected data after the last declared line");
    }
}

/// Parses a non-negative decimal integer made only of ASCII digits.
size_t parseCount(scope const(char)[] s) @safe pure
{
    if (s.length == 0)
        throw new FormatException("empty count line");
    size_t v;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new FormatException("malformed count line");
        immutable d = c - '0';
        if (v > (size_t.max - d) / 10)
            throw new FormatException("count out of range");
        v = v * 10 + d;
    }
    return v;
}
