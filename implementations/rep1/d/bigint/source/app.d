/// Command-line tool: reads queries from stdin, writes one result line per query to stdout.
module app;

import std.stdio : File, stderr, stdin, stdout;
import bigint.exceptions : BigIntException;
import bigint.query : processQueries;

int main()
{
    // Read all of stdin.
    ubyte[] data;
    {
        auto chunk = new ubyte[1 << 20];
        for (;;)
        {
            auto got = stdin.rawRead(chunk);
            if (got.length == 0)
                break;
            data ~= got;
        }
    }
    const text = cast(const(char)[]) data;

    // Buffer output and flush in large pieces.
    char[] buf;
    buf.reserve(1 << 20);
    void flush() @trusted
    {
        stdout.rawWrite(buf);
        buf.length = 0;
        assumeSafeAppend(buf);
    }

    try
    {
        processQueries(text, (scope const(char)[] s) @safe {
            buf ~= s;
            if (buf.length >= (1 << 20))
                (() @trusted => flush())();
        });
    }
    catch (BigIntException e)
    {
        (() @trusted => flush())();
        stderr.writeln("bigint: ", e.msg);
        return 1;
    }
    (() @trusted => flush())();
    stdout.flush();
    return 0;
}
