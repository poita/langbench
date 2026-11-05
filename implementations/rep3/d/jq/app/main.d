/// Command-line tool: reads a filter (first line) and a JSON document (the
/// rest) from stdin and prints each result as compact JSON, one per line.
/// If evaluation fails it prints `error` after the results produced so far.
module main;

import core.stdc.stdio : fread, fwrite, stdin, stdout, stderr, fputs, fflush;
import jq;

private enum flushThreshold = 1 << 16;

int main()
{
    // Read all of stdin.
    ubyte[] data = new ubyte[1 << 20];
    size_t len = 0;
    for (;;)
    {
        if (len == data.length)
            data.length = data.length * 2;
        immutable got = fread(data.ptr + len, 1, data.length - len, stdin);
        if (got == 0)
            break;
        len += got;
    }
    string text = cast(string) data[0 .. len];

    size_t nl = 0;
    while (nl < text.length && text[nl] != '\n')
        ++nl;
    string filter = text[0 .. nl];
    string doc = nl < text.length ? text[nl + 1 .. $] : "";

    Program prog;
    Value input;
    try
    {
        prog = compile(filter);
        input = parseJson(doc);
    }
    catch (ParseError e)
    {
        fputs("jq: ", stderr);
        fwrite(e.msg.ptr, 1, e.msg.length, stderr);
        fputs("\n", stderr);
        return 2;
    }

    Buf out_;
    void flush()
    {
        if (out_.len)
            fwrite(out_.data.ptr, 1, out_.len, stdout);
        out_.clear();
    }

    try
    {
        run(prog, input, (Value v) {
            writeJson(out_, v);
            out_.put('\n');
            if (out_.len >= flushThreshold)
                flush();
        });
    }
    catch (JqError)
    {
        out_.put("error\n");
    }
    flush();
    fflush(stdout);
    return 0;
}
