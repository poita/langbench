/// Command-line front end: reads commands on stdin, writes results to stdout.
module app;

import std.stdio : stdin, stdout;

import webhooks.buffer : OutBuffer;
import webhooks.commands : processInput;

/// Read all of standard input in large chunks.
private ubyte[] readAll()
{
    ubyte[] data;
    size_t used = 0;
    data.length = 1 << 20;
    while (true)
    {
        if (used == data.length)
            data.length = data.length * 2;
        auto got = stdin.rawRead(data[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }
    return data[0 .. used];
}

int main()
{
    auto input = readAll();
    OutBuffer output;
    processInput(input, output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
