/// Command-line tool: reads a batch of patterns and subjects on stdin,
/// writes one result line per subject on stdout.
module app.main;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : exit;
import std.stdio : stdin, stdout;

import regex.batch;
import regex.exception;

int main()
{
    ubyte[] input = new ubyte[1 << 20];
    size_t used = 0;
    for (;;)
    {
        if (used == input.length)
            input.length = input.length * 2;
        auto got = stdin.rawRead(input[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }

    OutputBuffer output;
    try
        processBatch(input[0 .. used], output);
    catch (RegexException e)
    {
        fprintf(stderr, "regex: invalid pattern: %.*s\n", cast(int) e.msg.length, e.msg.ptr);
        return 1;
    }
    stdout.rawWrite(output.bytes);
    stdout.flush();
    return 0;
}
