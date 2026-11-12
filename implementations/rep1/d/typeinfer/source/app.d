/**
 * Command-line tool: reads a program on stdin, writes one line per declaration.
 */
module app;

import core.thread : Thread;
import std.stdio : stderr, stdin, stdout;
import typeinfer : checkSource;

/// Inference and parsing recurse as deeply as the program nests, so run them on a big stack.
enum stackBytes = 1024UL * 1024 * 1024;

int main()
{
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(1 << 16)) raw ~= chunk;
    immutable source = cast(string) raw.idup;

    string output, syntaxError;
    auto worker = new Thread({
        auto report = checkSource(source);
        output = report.output;
        syntaxError = report.syntaxError;
    }, stackBytes);
    worker.start();
    worker.join();

    stdout.rawWrite(output);
    stdout.flush();
    if (syntaxError.length) stderr.writeln(syntaxError);
    return 0;
}
