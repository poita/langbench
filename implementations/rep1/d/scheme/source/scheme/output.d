/**
 * Buffered output sink used by the interpreter.
 *
 * `display`, `newline` and the top-level result printer all write through an
 * $(LREF Output). Output either streams to a user-supplied delegate (the CLI
 * uses this to write to stdout) or, when no delegate is given, accumulates in
 * memory so that it can be collected with $(LREF Output.take).
 */
module scheme.output;

/// Callback receiving chunks of output.
alias OutputSink = void delegate(const(char)[] chunk);

/// A write buffer in front of an optional sink.
final class Output
{
    private enum flushThreshold = 1 << 16;

    private OutputSink sink;
    private char[] buffer;

    /// Create an output. With a null `sink`, everything is kept in memory.
    this(OutputSink sink = null) nothrow
    {
        this.sink = sink;
        buffer.reserve(flushThreshold);
    }

    /// Append text.
    void put(const(char)[] text)
    {
        buffer ~= text;
        if (sink !is null && buffer.length >= flushThreshold)
            flush();
    }

    /// Append one character.
    void put(char c)
    {
        buffer ~= c;
        if (sink !is null && buffer.length >= flushThreshold)
            flush();
    }

    /// Hand buffered text to the sink (no-op for in-memory outputs).
    void flush()
    {
        if (sink is null || buffer.length == 0)
            return;
        sink(buffer);
        buffer.length = 0;
        buffer.assumeSafeAppend();
    }

    /// Return and clear the text accumulated by an in-memory output.
    string take()
    {
        auto s = buffer.idup;
        buffer.length = 0;
        buffer.assumeSafeAppend();
        return s;
    }
}

unittest
{
    auto o = new Output();
    o.put("ab");
    o.put('c');
    assert(o.take() == "abc");
    assert(o.take() == "");
}

unittest
{
    string got;
    auto o = new Output((const(char)[] c) { got ~= c; });
    o.put("hello");
    assert(got == "");
    o.flush();
    assert(got == "hello");
}
