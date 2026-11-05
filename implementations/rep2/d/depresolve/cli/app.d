/// Command-line front end: reads the registry and root manifest on stdin and
/// writes the resolution on stdout.
module app;

import std.array : appender;
import std.exception : assumeUnique;
import std.stdio : stderr, stdin, stdout;

import depresolve;

int main()
{
    auto buf = appender!(char[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        buf.put(cast(const(char)[]) chunk);
    immutable text = assumeUnique(buf.data);

    try
    {
        stdout.write(solve(text));
        stdout.flush();
    }
    catch (ParseException e)
    {
        stderr.writeln("depresolve: ", e.msg);
        return 2;
    }
    return 0;
}
