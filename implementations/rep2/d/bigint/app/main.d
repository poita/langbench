/// Command-line tool: reads queries (`<a> <op> <b>`, one per line) from
/// standard input and writes one result line per query to standard output.
module app.main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import bigint.queries : evalQueries;

/// Reads all of standard input into one buffer.
private char[] readAll()
{
    char[] buf = new char[1 << 20];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(cast(ubyte[]) buf[len .. $]);
        if (got.length == 0)
            break;
        len += got.length;
    }
    return buf[0 .. len];
}

int main()
{
    auto input = readAll();
    auto output = appender!(char[])();
    output.reserve(input.length + 64);
    try
        evalQueries(output, input);
    catch (Exception e)
    {
        stderr.writeln("bigint: ", e.msg);
        return 1;
    }
    stdout.rawWrite(output[]);
    stdout.flush();
    return 0;
}
