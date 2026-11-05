/**
 * Command-line front end: reads a filter (first line) and a JSON document
 * (the rest) from stdin and prints each result as compact JSON.
 */
module app;

import core.stdc.stdio : fread, fwrite, stdin, stdout, fflush;

import jq;

private ubyte[] readAllStdin()
{
    ubyte[] buf = new ubyte[1 << 20];
    size_t len = 0;
    while (true)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        const n = fread(buf.ptr + len, 1, buf.length - len, stdin);
        if (n == 0)
            break;
        len += n;
    }
    return buf[0 .. len];
}

private void flush(ref Buffer out_)
{
    if (out_.len)
        fwrite(out_.data.ptr, 1, out_.len, stdout);
    out_.clear();
}

int main()
{
    auto all = cast(string) readAllStdin();
    size_t nl = 0;
    while (nl < all.length && all[nl] != '\n')
        ++nl;
    const filterText = all[0 .. nl];
    const docText = nl < all.length ? all[nl + 1 .. $] : "";

    Buffer out_;
    out_.reserve(1 << 16);
    try
    {
        auto program = Program.compile(filterText);
        auto doc = parseJson(docText);
        const status = program.run(doc, (Value v) {
            writeValue(out_, v);
            out_.put('\n');
            if (out_.len >= (1 << 16))
                flush(out_);
        });
        if (!status.ok)
            out_.put("error\n");
    }
    catch (Exception e)
    {
        out_.put("error\n");
    }
    flush(out_);
    fflush(stdout);
    return 0;
}
