/// Command-line front end: reads a batch on stdin, writes the results to stdout.
module main;

import core.stdc.stdio : fread, fwrite, stdin, stdout, fputs, stderr, fflush;
import core.stdc.stdlib : malloc, realloc, exit;

import regex.batch;
import regex.parser : RegexException;

/// Reads all of stdin with bulk reads.
const(ubyte)[] readAll() @trusted
{
    size_t cap = 1 << 20, len = 0;
    ubyte* buf = cast(ubyte*) malloc(cap);
    for (;;)
    {
        if (len == cap)
        {
            cap *= 2;
            buf = cast(ubyte*) realloc(buf, cap);
        }
        const got = fread(buf + len, 1, cap - len, stdin);
        if (got == 0)
            break;
        len += got;
    }
    return buf[0 .. len];
}

int main()
{
    const input = readAll();
    OutputBuffer output;
    try
        processBatch(input, output);
    catch (RegexException e)
    {
        fputs("regex-cli: invalid pattern: ", stderr);
        fputs((e.msg ~ "\n\0").ptr, stderr);
        return 2;
    }
    catch (BatchFormatException e)
    {
        fputs("regex-cli: malformed input: ", stderr);
        fputs((e.msg ~ "\n\0").ptr, stderr);
        return 2;
    }
    const bytes = output.bytes;
    if (bytes.length)
        fwrite(bytes.ptr, 1, bytes.length, stdout);
    fflush(stdout);
    return 0;
}
