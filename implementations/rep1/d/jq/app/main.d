/// Command-line tool: reads a filter (first line) and a JSON document (the
/// rest) from stdin; prints each result as one line of compact JSON.
module app.main;

import core.stdc.stdio : fread, fwrite, fflush, stdin, stdout;

import std.array : appender;

import jq;

/// Reads all of stdin.
private string readAll()
{
    char[] buf = new char[1 << 20];
    size_t n = 0;
    while (true)
    {
        if (n == buf.length)
            buf.length = buf.length * 2;
        immutable got = fread(buf.ptr + n, 1, buf.length - n, stdin);
        if (got == 0)
            break;
        n += got;
    }
    return cast(string) buf[0 .. n];
}

private void flush(ref JsonBuffer buf)
{
    if (buf.data.length)
        fwrite(buf.data.ptr, 1, buf.data.length, stdout);
    buf.clear();
}

int main()
{
    auto input = readAll();
    size_t nl = 0;
    while (nl < input.length && input[nl] != '\n')
        ++nl;
    auto filterText = input[0 .. nl];
    auto docText = nl < input.length ? input[nl + 1 .. $] : "";

    auto out_ = appender!(char[])();
    try
    {
        auto filter = Filter.compile(filterText);
        auto doc = parseJson(docText);
        try
        {
            filter.run(doc, (Value v) {
                writeJson(out_, v);
                out_.put('\n');
                if (out_.data.length >= (1 << 16))
                    flush(out_);
            });
        }
        catch (JqError)
        {
            out_.put("error\n");
        }
    }
    catch (JqException)
    {
        // Malformed filter or document: the specification excludes these.
        out_.put("error\n");
    }
    flush(out_);
    fflush(stdout);
    return 0;
}
