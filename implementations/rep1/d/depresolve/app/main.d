/// Command-line front end: reads a registry and root manifest on stdin, prints the resolution.
module main;

import std.stdio : stdin, stdout, stderr;
import depresolve;

int main()
{
    // Read all of standard input.
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(1 << 16))
        raw ~= chunk;
    auto text = cast(string) raw.idup;

    try
    {
        auto problem = parseProblem(text);
        auto resolution = resolve(problem.registry, problem.root);
        stdout.write(formatResolution(resolution));
        return 0;
    }
    catch (SyntaxException e)
    {
        stderr.writeln("depresolve: malformed input: ", e.msg);
        return 2;
    }
}
