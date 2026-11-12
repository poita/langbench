/**
 * Command-line front end: reads the batch input on stdin and writes one
 * result line per subject to stdout. See the project README.
 */
module app;

import core.stdc.stdio : stdin, stdout, fread, fwrite, stderr, fputs;
import regex;

private ubyte[] readAll()
{
    ubyte[] data;
    data.length = 1 << 20;
    size_t used = 0;
    for (;;)
    {
        if (used == data.length)
            data.length = data.length * 2;
        immutable got = fread(data.ptr + used, 1, data.length - used, stdin);
        if (got == 0)
            break;
        used += got;
    }
    return data[0 .. used];
}

int main(string[] args)
{
    if (args.length > 1)
    {
        fputs("usage: regex < input > output\n", stderr);
        return 2;
    }
    auto input = cast(const(char)[]) readAll();
    try
    {
        processInput(input, (const(char)[] chunk) {
            fwrite(chunk.ptr, 1, chunk.length, stdout);
        });
    }
    catch (Exception e)
    {
        import std.string : toStringz;
        import core.stdc.stdio : fflush;
        fflush(stdout);
        fputs(("regex: " ~ e.msg ~ "\n").toStringz, stderr);
        return 1;
    }
    return 0;
}
