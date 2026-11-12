/// Command-line front end for the inflate library.
///
/// Reads one line of hex (a raw DEFLATE stream) from stdin and writes one line
/// to stdout: the decompressed data as lowercase hex, or `error` if the stream
/// is malformed.
module app;

import inflate;
import std.stdio : stderr, stdin, stdout;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: inflate-cli < hex-deflate-stream");
        return 2;
    }

    ubyte[] hexBytes;
    {
        auto chunk = new ubyte[1 << 20];
        for (;;)
        {
            auto got = stdin.rawRead(chunk);
            if (got.length == 0)
                break;
            hexBytes ~= got;
        }
    }

    // Ignore leading/trailing whitespace.
    auto text = cast(const(char)[]) hexBytes;
    while (text.length && isSpace(text[0]))
        text = text[1 .. $];
    while (text.length && isSpace(text[$ - 1]))
        text = text[0 .. $ - 1];

    ubyte[] compressed;
    try
        compressed = fromHex(text);
    catch (InflateException e)
    {
        stderr.writeln("inflate-cli: invalid input: ", e.msg);
        return 2;
    }

    ubyte[] raw;
    if (tryDecompress(compressed, raw))
        stdout.rawWrite(toHex(raw));
    else
        stdout.rawWrite("error");
    stdout.rawWrite("\n");
    return 0;
}

private bool isSpace(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\n' || c == '\r' || c == '\t';
}
