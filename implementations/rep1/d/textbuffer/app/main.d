/// Command-line front end: reads a script on stdin, writes the output of its
/// `print` commands to stdout.
module main;

import std.stdio : stderr, stdin, stdout;

import textbuffer;

/// Reads all of standard input with a growing buffer.
private char[] readAll()
{
    auto buf = new char[](1 << 20);
    size_t used = 0;
    while (true)
    {
        if (used == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(buf[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }
    return buf[0 .. used];
}

int main()
{
    auto input = readAll();
    CharBuf output;
    int status = 0;
    try
        runScript(input, output);
    catch (ScriptException e)
    {
        stderr.writeln("textbuffer: ", e.msg);
        status = 1;
    }
    stdout.rawWrite(output[]);
    stdout.flush();
    return status;
}
