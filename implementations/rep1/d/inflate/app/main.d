/// Command-line front end: hex DEFLATE stream on stdin, hex result on stdout.
module app.main;

import std.stdio : stderr, stdin, stdout;

import inflate;

/// Reads all of standard input into one buffer, growing it geometrically.
ubyte[] readAll()
{
    auto buf = new ubyte[1 << 20];
    size_t used = 0;
    for (;;)
    {
        if (used == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(buf[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }
    return buf[0 .. used];
}

int main()
{
    auto input = readAll();

    // Trim surrounding whitespace.
    size_t a = 0, b = input.length;
    while (a < b && input[a] <= ' ') a++;
    while (b > a && input[b - 1] <= ' ') b--;

    ubyte[] stream;
    try
        stream = hexDecode(cast(const(char)[]) input[a .. b]);
    catch (HexException e)
    {
        stderr.writeln("inflate: ", e.msg);
        return 2;
    }

    ubyte[] result;
    InflateError err;
    if (!tryDecompress(stream, result, err))
        stdout.rawWrite("error\n");
    else
        stdout.rawWrite(hexEncode(result, "\n"));
    return 0;
}
