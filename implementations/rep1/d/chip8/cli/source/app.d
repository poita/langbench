/// Command-line front end: reads a CHIP-8 job from stdin, writes the report to stdout.
module app;

import std.stdio : stderr, stdin, stdout;
import chip8.program : simulate;

int main()
{
    try
    {
        // Read all of stdin as raw bytes.
        char[] text;
        foreach (chunk; stdin.byChunk(64 * 1024))
            text ~= cast(const(char)[]) chunk;
        stdout.rawWrite(simulate(text.idup));
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("chip8: ", e.msg);
        return 1;
    }
}
