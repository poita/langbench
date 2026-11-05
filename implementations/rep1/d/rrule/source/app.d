/// Command-line front end: reads rules on stdin, writes occurrences on stdout.
module app;

import std.stdio : File, stderr, stdin, stdout;

import rrule.batch;
import rrule.errors;

int main(string[] args)
{
    // Bulk-read all of standard input.
    ubyte[] input;
    size_t used = 0;
    input.length = 1 << 20;
    while (true)
    {
        if (used == input.length)
            input.length = input.length * 2;
        auto got = stdin.rawRead(input[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }

    OutputBuffer output;
    scope void delegate(const(ubyte)[]) flush = (const(ubyte)[] chunk) { stdout.rawWrite(chunk); };
    int status = 0;
    try
        processInput(cast(const(char)[]) input[0 .. used], output, flush);
    catch (RRuleException e)
    {
        if (output.length)
            flush(output.contents);
        stderr.writeln("rrule: ", e.msg);
        status = 1;
    }
    stdout.flush();
    return status;
}
