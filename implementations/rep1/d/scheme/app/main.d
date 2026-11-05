/// Command-line tool: reads a Scheme program on stdin, writes its output to stdout.
module main;

import std.stdio : stdin, stdout;
import scheme;

int main()
{
    ubyte[] data;
    auto buf = new ubyte[](1 << 16);
    for (;;)
    {
        auto got = stdin.rawRead(buf);
        if (got.length == 0)
            break;
        data ~= got;
    }
    stdout.rawWrite(runProgram(cast(string) data.idup));
    stdout.flush();
    return 0;
}
