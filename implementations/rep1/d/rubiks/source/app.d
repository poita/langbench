/**
 * Command-line tool: reads scrambles (one per line) on standard input and
 * prints a solution for each on standard output.
 */
module app;

import std.stdio : stderr, stdin, stdout;
import rubiks;

/// Reads everything from standard input.
private char[] readAll()
{
    import std.array : appender;

    auto buf = appender!(char[]);
    foreach (chunk; stdin.byChunk(1 << 20))
        buf.put(cast(const(char)[]) chunk);
    return buf[];
}

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: rubiks < scrambles.txt > solutions.txt");
        return args[1] == "-h" || args[1] == "--help" ? 0 : 2;
    }

    try
    {
        auto lines = splitLines(readAll());
        stdout.rawWrite(solveLines(new Solver, lines));
    }
    catch (MoveParseException e)
    {
        stderr.writeln("rubiks: ", e.msg);
        return 1;
    }
    return 0;
}
