/// Command-line front end: reads a Datalog program on stdin, writes the
/// answers to its queries on stdout, or `error` when the program is unsafe or
/// not stratifiable.
module app;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import datalog;

int main()
{
    auto input = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        input.put(chunk);
    immutable source = cast(string) input[].idup;

    string output;
    try
        output = solve(source);
    catch (DatalogException e)
    {
        stderr.writeln(e.msg);
        output = "error\n";
    }
    stdout.write(output);
    return 0;
}
