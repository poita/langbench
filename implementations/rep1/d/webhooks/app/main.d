/**
 * Command-line front end: reads commands from stdin, writes results to stdout.
 */
module app;

import std.stdio : stdin, stdout;
import webhooks.protocol : processInput;

/// Buffers output and flushes it to stdout in large chunks.
private struct StdoutSink
{
    private char[] buffer;
    private enum flushThreshold = 1 << 16;

    void put(scope const(char)[] text)
    {
        buffer ~= text;
        if (buffer.length >= flushThreshold)
            flush();
    }

    void flush()
    {
        stdout.rawWrite(buffer);
        buffer.length = 0;
        buffer.assumeSafeAppend();
    }
}

/// Reads all of stdin as bytes.
private ubyte[] readAll()
{
    ubyte[] data;
    auto chunk = new ubyte[1 << 16];
    for (;;)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        data ~= got;
    }
    return data;
}

int main()
{
    auto input = readAll();
    StdoutSink sink;
    processInput(input, sink);
    sink.flush();
    stdout.flush();
    return 0;
}
