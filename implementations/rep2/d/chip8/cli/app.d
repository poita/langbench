/// Command-line entry point: reads a program on stdin, prints the final state.
module app;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import chip8;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: chip8 < input   (no arguments; see README.md)");
        return 2;
    }

    auto text = appender!(char[]);
    foreach (chunk; stdin.byChunk(64 * 1024))
        text.put(cast(const(char)[]) chunk);

    try
        stdout.write(simulate(text.data));
    catch (ParseException e)
    {
        stderr.writeln("chip8: invalid input: ", e.msg);
        return 1;
    }
    return 0;
}
