/// Command-line front end: reads a Datalog program on stdin, writes the query
/// answers (or `error`) on stdout.
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import datalog;

int main()
{
    auto input = appender!(char[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        input.put(cast(const(char)[]) chunk);

    try
    {
        const result = solve(cast(string) input.data);
        stdout.rawWrite(result.output);
        return 0;
    }
    catch (ParseException e)
    {
        stderr.writeln("datalog: ", e.msg);
        return 1;
    }
}
