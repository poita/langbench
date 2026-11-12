/// Command-line front end: reads a filter (first line) and a JSON document
/// (the rest) from stdin and prints every result as compact JSON.
module app.main;

import core.stdc.stdio : fwrite, stdout, fflush;
import std.stdio : stdin, stderr;
import std.array : appender;

import jq;

/// Buffered stdout writer usable as an output range.
private struct StdoutSink
{
    char[] buf;
    size_t len;

    this(size_t size)
    {
        buf = new char[size];
    }

    void flush()
    {
        if (len)
            fwrite(buf.ptr, 1, len, stdout);
        len = 0;
    }

    void put(const(char)[] s)
    {
        if (s.length > buf.length - len)
        {
            flush();
            if (s.length > buf.length)
            {
                fwrite(s.ptr, 1, s.length, stdout);
                return;
            }
        }
        buf[len .. len + s.length] = s[];
        len += s.length;
    }

    void put(char c)
    {
        if (len == buf.length)
            flush();
        buf[len++] = c;
    }
}

private string readAll()
{
    auto data = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 20))
        data.put(chunk);
    return cast(string) data.data;
}

int main()
{
    auto text = readAll();
    size_t nl = 0;
    while (nl < text.length && text[nl] != '\n')
        nl++;
    auto filterText = text[0 .. nl];
    if (filterText.length && filterText[$ - 1] == '\r')
        filterText = filterText[0 .. $ - 1];
    auto docText = nl < text.length ? text[nl + 1 .. $] : "";

    auto out_ = StdoutSink(1 << 16);
    scope (exit)
    {
        out_.flush();
        fflush(stdout);
    }
    try
    {
        auto filter = Filter.compile(filterText);
        auto doc = parseJson(docText);
        try
        {
            filter.run(doc, (Value v) {
                writeJson(out_, v);
                out_.put('\n');
            });
        }
        catch (JqError e)
        {
            out_.put("error\n");
        }
    }
    catch (Exception e)
    {
        stderr.writeln("jq: ", e.msg);
    }
    return 0;
}
