/// Command-line tool: reads spreadsheet commands on stdin, writes results to stdout.
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import spreadsheet;

int main()
{
    // Read all input at once.
    auto raw = appender!(ubyte[])();
    foreach (chunk; stdin.byChunk(1 << 20))
        raw.put(chunk);
    string input = cast(string) raw.data;

    auto output = appender!(char[])();
    auto sheet = new Sheet;
    int status = 0;
    try
        executeScript(sheet, input, output);
    catch (Exception e)
    {
        stderr.writeln("spreadsheet: ", e.msg);
        status = 1;
    }
    stdout.rawWrite(output.data);
    stdout.flush();
    return status;
}
