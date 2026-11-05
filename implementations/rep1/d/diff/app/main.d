/// Command-line front end: reads a request on stdin, writes the response to stdout.
module main;

import core.stdc.stdlib : exit;
import std.stdio : File, stderr, stdin, stdout;
import mdiff.errors : MdiffException;
import mdiff.protocol : process;

/// Reads all of `f` into one buffer.
private char[] readAll(File f)
{
    char[] buf = new char[](1 << 16);
    size_t len;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        auto got = f.rawRead(buf[len .. $]);
        if (got.length == 0)
            break;
        len += got.length;
    }
    return buf[0 .. len];
}

int main()
{
    try
    {
        auto input = readAll(stdin);
        auto output = process(input);
        stdout.rawWrite(output);
        stdout.flush();
        return 0;
    }
    catch (MdiffException e)
    {
        stderr.writeln("mdiff: ", e.msg);
        return 1;
    }
}
