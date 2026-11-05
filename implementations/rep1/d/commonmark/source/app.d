/// Command-line front end: reads Markdown on stdin, writes HTML on stdout.
module app;

import commonmark;
import std.stdio : stdin, stdout, stderr;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: commonmark < input.md > output.html");
        return 2;
    }
    char[] input;
    foreach (chunk; stdin.byChunk(1 << 16))
        input ~= cast(const(char)[]) chunk;

    Buffer output;
    output.reserve(input.length * 2 + 64);
    toHtml(input, output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
