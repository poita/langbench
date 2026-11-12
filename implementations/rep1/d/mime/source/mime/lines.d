/// Line splitting and line-ending normalisation over raw bytes.
///
/// A line ends at the next LF; the LF and a single CR immediately before it
/// are the terminator and not part of the line.  A trailing LF does not
/// produce a final empty line.
module mime.lines;

import core.stdc.string : memchr;

@safe:

/// One line of a byte string, as offsets into that string.
struct Line
{
    size_t start;      /// first byte of the line
    size_t end;        /// one past the last content byte (terminator excluded)
    size_t next;       /// first byte after the terminator (the next line's start)
    bool terminated;   /// whether the line had an LF terminator

    /// Number of content bytes.
    size_t length() const pure nothrow @nogc { return end - start; }
}

/// Returns the line that starts at `pos`; requires `pos < data.length`.
Line nextLine(const(ubyte)[] data, size_t pos) pure nothrow @nogc @trusted
{
    assert(pos < data.length);
    const rest = data[pos .. $];
    const p = cast(const(ubyte)*) memchr(rest.ptr, '\n', rest.length);
    Line ln;
    ln.start = pos;
    if (p is null)
    {
        ln.end = data.length;
        ln.next = data.length;
        ln.terminated = false;
        return ln;
    }
    const lf = pos + (p - rest.ptr);
    ln.terminated = true;
    ln.next = lf + 1;
    ln.end = (lf > pos && data[lf - 1] == '\r') ? lf - 1 : lf;
    return ln;
}

/// Replaces every CRLF with LF; everything else is unchanged.
/// Returns the input itself when it contains no CRLF.
const(ubyte)[] normalizeLineEndings(const(ubyte)[] data) pure nothrow
{
    bool any = false;
    foreach (i; 1 .. data.length)
        if (data[i] == '\n' && data[i - 1] == '\r')
        {
            any = true;
            break;
        }
    if (!any)
        return data;
    auto result = new ubyte[data.length];
    size_t n = 0;
    foreach (i, b; data)
    {
        if (b == '\r' && i + 1 < data.length && data[i + 1] == '\n')
            continue;
        result[n++] = b;
    }
    return result[0 .. n];
}

@safe pure nothrow unittest
{
    auto d = cast(const(ubyte)[]) "a\r\nb\n\r\nc\r";
    auto ln = nextLine(d, 0);
    assert(ln.start == 0 && ln.end == 1 && ln.next == 3 && ln.terminated);
    ln = nextLine(d, ln.next);
    assert(ln.end == 4 && ln.next == 5);
    ln = nextLine(d, ln.next);
    assert(ln.length == 0 && ln.terminated);
    ln = nextLine(d, ln.next);
    assert(ln.start == 7 && ln.end == 9 && !ln.terminated);
    assert(normalizeLineEndings(d) == cast(const(ubyte)[]) "a\nb\n\nc\r");
}
