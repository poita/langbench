/// The line-oriented batch format used by the command-line tool.
///
/// Input is `N`, then for each pattern a pattern line, a count `M` and `M`
/// subject lines. For every subject one output line is produced: `no`, or
/// `match S E` followed by `|gs,ge` (or `|-`) for each group.
module btregex.batch;

import btregex.engine;

/// Thrown when the batch input is malformed.
class BatchFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Growable output buffer that hands full chunks to a sink delegate.
struct OutputBuffer
{
    private ubyte[] buf;
    private size_t used;
    private void delegate(const(ubyte)[]) sink;
    private enum chunk = 1 << 20;

    this(void delegate(const(ubyte)[]) sink)
    {
        this.sink = sink;
        buf = new ubyte[chunk + 4096];
    }

    /// Appends a character.
    void put(char c) @safe
    {
        buf[used++] = c;
    }

    /// Appends a non-negative decimal number.
    void putNumber(long v) @safe
    {
        char[20] tmp = void;
        size_t n = 0;
        do
        {
            tmp[n++] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v > 0);
        while (n)
            buf[used++] = tmp[--n];
    }

    /// Appends a string.
    void put(const(char)[] s) @safe
    {
        foreach (c; s)
            buf[used++] = c;
    }

    /// Call after each complete line (at most 4096 bytes): flushes when the buffer is large.
    void endLine() @safe
    {
        buf[used++] = '\n';
        if (used >= chunk)
            flush();
    }

    /// Writes any buffered output to the sink.
    void flush() @trusted
    {
        if (used)
            sink(buf[0 .. used]);
        used = 0;
    }
}

/// Appends the result line for `m` (without newline) to `o`.
void formatMatch(ref OutputBuffer o, const ref Match m) @safe
{
    if (!m.matched)
    {
        o.put("no");
        return;
    }
    o.put("match ");
    o.putNumber(m.start);
    o.put(' ');
    o.putNumber(m.end);
    foreach (g; m.groups)
    {
        o.put('|');
        if (g.isSet)
        {
            o.putNumber(g.start);
            o.put(',');
            o.putNumber(g.end);
        }
        else
            o.put('-');
    }
}

/// Processes a complete batch `input`, passing output chunks to `sink`.
void runBatch(const(ubyte)[] input, scope void delegate(const(ubyte)[]) sink) @trusted
{
    import core.stdc.string : memchr;

    size_t pos = 0;

    const(char)[] nextLine()
    {
        if (pos >= input.length)
            throw new BatchFormatException("unexpected end of input");
        auto rest = input[pos .. $];
        auto p = cast(const(ubyte)*) memchr(rest.ptr, '\n', rest.length);
        size_t n = p is null ? rest.length : p - rest.ptr;
        auto line = cast(const(char)[]) rest[0 .. n];
        pos += n + 1;
        return line;
    }

    long number(const(char)[] line)
    {
        if (line.length == 0 || line.length > 18)
            throw new BatchFormatException("bad number");
        long v = 0;
        foreach (c; line)
        {
            if (c < '0' || c > '9')
                throw new BatchFormatException("bad number");
            v = v * 10 + (c - '0');
        }
        return v;
    }

    auto out_ = OutputBuffer(sink);
    const n = number(nextLine());
    Match m;
    foreach (_; 0 .. n)
    {
        auto re = new Regex(nextLine());
        const count = number(nextLine());
        foreach (__; 0 .. count)
        {
            re.search(nextLine(), m);
            formatMatch(out_, m);
            out_.endLine();
        }
    }
    out_.flush();
}

unittest
{
    ubyte[] result;
    void collect(const(ubyte)[] b)
    {
        result ~= b;
    }

    runBatch(cast(const(ubyte)[]) "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n\n0\n", &collect);
    assert(cast(string) result == "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\n");
}
