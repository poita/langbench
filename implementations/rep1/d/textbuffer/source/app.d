/// Command-line front end: reads a document and commands from stdin, writes the
/// output of `print` commands to stdout.
module app;

import std.array : appender;
import std.stdio : File, stderr, stdin, stdout;

import textbuffer.script;

/// A buffered stdout writer usable as an output range.
private struct StdoutSink
{
    File file;
    char[] buf;
    size_t used;

    this(File f)
    {
        file = f;
        buf = new char[](1 << 16);
    }

    void put(const(char)[] s)
    {
        if (s.length >= buf.length)
        {
            flush();
            file.rawWrite(s);
            return;
        }
        if (used + s.length > buf.length)
            flush();
        buf[used .. used + s.length] = s[];
        used += s.length;
    }

    void flush()
    {
        if (used)
            file.rawWrite(buf[0 .. used]);
        used = 0;
    }
}

private string readAll(File f)
{
    import std.exception : assumeUnique;

    auto data = appender!(char[])();
    auto chunk = new char[](1 << 20);
    for (;;)
    {
        auto got = f.rawRead(chunk);
        if (got.length == 0)
            break;
        data.put(got);
    }
    return assumeUnique(data[]);
}

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: textbuffer < script   (no arguments)");
        return 2;
    }
    auto input = readAll(stdin);
    auto sink = StdoutSink(stdout);
    int status = 0;
    try
        runScript(input, sink);
    catch (ScriptException e)
    {
        stderr.writefln("textbuffer: line %s: %s", e.lineNumber, e.msg);
        status = 1;
    }
    sink.flush();
    stdout.flush();
    return status;
}
