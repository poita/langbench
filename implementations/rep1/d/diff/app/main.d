/// Command-line front end: reads a request on stdin, writes the response on stdout.
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;
import myersdiff;

int main()
{
    auto input = appender!(ubyte[]);
    ubyte[1 << 16] buf;
    for (;;)
    {
        auto got = stdin.rawRead(buf[]);
        if (got.length == 0)
            break;
        input.put(got);
    }

    auto sink = appender!(char[]);
    try
        process(cast(const(char)[]) input.data, sink);
    catch (Exception e)
    {
        stderr.writeln("diff: ", e.msg);
        return 1;
    }
    stdout.rawWrite(sink.data);
    return 0;
}
