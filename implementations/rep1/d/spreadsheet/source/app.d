/// Command-line driver: reads spreadsheet commands on stdin, writes results to stdout.
module app;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;
import spreadsheet;

int main()
{
    auto input = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        input ~= chunk;
    const script = cast(string) input[].idup;

    auto output = appender!(char[]);
    auto sheet = new Sheet;
    int status = 0;
    try
        runScript(sheet, script, (const(char)[] s) { output ~= s; });
    catch (Exception e)
    {
        stderr.writeln("spreadsheet: ", e.msg);
        status = 1;
    }
    stdout.rawWrite(output[]);
    return status;
}
