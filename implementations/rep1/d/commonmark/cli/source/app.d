/// Command-line tool: reads a Markdown document on stdin and writes the HTML
/// on stdout.
module app;

import commonmark : toHtml;
import core.memory : GC;
import std.stdio : stderr, stdin, stdout;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: commonmark < input.md > output.html");
        return args[1] == "-h" || args[1] == "--help" ? 0 : 2;
    }
    // The process is short lived; skip garbage collection pauses.
    GC.disable();

    ubyte[] data;
    foreach (chunk; stdin.byChunk(1 << 16))
        data ~= chunk;
    immutable markdown = (() @trusted => cast(string) data.idup)();

    stdout.rawWrite(toHtml(markdown));
    return 0;
}
