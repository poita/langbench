/**
 * canonjson command-line tool.
 *
 * Reads one JSON document from stdin and writes its canonical form, or the
 * line `invalid`, to stdout. The exit code is 0 either way.
 */
module main;

import std.stdio : stdin, stdout;

import canonjson;

/// Reads all of stdin into one buffer.
ubyte[] readAll()
{
    auto buf = new ubyte[1 << 16];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(buf[len .. $]);
        if (got.length == 0)
            break;
        len += got.length;
    }
    return buf[0 .. len];
}

int main()
{
    auto input = readAll();
    ByteBuffer output = ByteBuffer(input.length + 64);
    try
    {
        auto doc = parse(input);
        serialize(doc, output);
    }
    catch (ParseException)
    {
        output.clear();
        output.put("invalid");
    }
    output.put('\n');
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
