/**
 * Command-line front end: reads one scramble per line from standard input and
 * prints one solution per line to standard output.
 */
module app;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import rubiks;

int main()
{
    // Read all of standard input.
    auto input = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        input.put(chunk);
    const(char)[] text = cast(const(char)[]) input.data;

    // Split on '\n'.  A final newline terminates the last line rather than
    // starting another (empty) one.
    const(char)[][] lines;
    size_t start = 0;
    foreach (i, ch; text)
        if (ch == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];

    auto solver = new Solver;
    auto output = appender!(char[]);
    output.reserve(lines.length * 128);
    foreach (n, line; lines)
    {
        try
        {
            writeMoves(output, solver.solve(line));
        }
        catch (Exception e)
        {
            stderr.writefln("rubiks: line %d: %s", n + 1, e.msg);
            return 1;
        }
        output.put('\n');
    }
    stdout.rawWrite(output.data);
    return 0;
}
