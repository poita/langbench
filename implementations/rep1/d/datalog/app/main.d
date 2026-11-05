/// Command-line front end: read a Datalog program on stdin, print query answers on stdout.
module app.main;

import std.stdio : File, stderr, stdin, stdout;

import datalog : ParseException, runProgram;

int main()
{
    import std.array : appender;

    auto text = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        text.put(chunk);
    auto source = cast(string) text.data.idup;

    try
    {
        stdout.rawWrite(runProgram(source));
    }
    catch (ParseException e)
    {
        stderr.writeln("datalog: ", e.msg);
        return 1;
    }
    return 0;
}
