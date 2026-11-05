/// Command-line tool: reads the batch format on stdin, writes one result line
/// per subject on stdout.
module main;

import core.stdc.stdlib : exit;
import std.stdio : stderr, stdin, stdout;
import regexvm;

private ubyte[] readAll()
{
    ubyte[] buf = new ubyte[1 << 20];
    size_t len;
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
    OutputBuffer output;
    try
        runBatch(input, output);
    catch (Exception e)
    {
        stderr.writeln("regex: ", e.msg);
        return 2;
    }
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
