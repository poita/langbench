/// Command-line tool: read a Scheme program on stdin, run it, write the results to stdout.
module app;

import std.stdio : stdin, stdout;

import scheme;

int main(string[] args)
{
    ubyte[] data;
    foreach (chunk; stdin.byChunk(1 << 16))
        data ~= chunk;
    string source = cast(string) data;

    auto interp = new Interpreter((const(char)[] chunk) { stdout.rawWrite(chunk); });
    // Non-tail recursion nests on the host stack, so run on a big one.
    withLargeStack({ interp.run(source); });
    stdout.flush();
    return 0; // errors inside the Scheme program are normal output
}
