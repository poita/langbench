/// Command-line front end: reads a Datalog program on stdin and prints the answers
/// to its queries on stdout (or `error`).
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;
import datalog;

int main()
{
    auto buf = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        buf.put(chunk);
    try
    {
        immutable output = solve(cast(string) buf.data);
        stdout.rawWrite(output);
    }
    catch (ParseException e)
    {
        stderr.writefln("parse error at byte %s: %s", e.offset, e.msg);
        return 2;
    }
    return 0;
}
