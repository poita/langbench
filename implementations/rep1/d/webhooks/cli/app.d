/// Command-line front end: reads the command stream on stdin, writes results to stdout.
module app;

import std.stdio : stdin, stdout;
import webhooks.buffer : ByteSink;
import webhooks.commands : processInput;

/// Reads all of standard input into one buffer.
ubyte[] readAll()
{
    ByteSink acc;
    enum chunk = 1 << 20;
    ubyte[] tmp = new ubyte[chunk];
    for (;;)
    {
        auto got = stdin.rawRead(tmp);
        if (got.length == 0)
            break;
        acc.put(got);
    }
    return acc.data.dup;
}

int main()
{
    auto input = readAll();
    ByteSink output;
    processInput(input, output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
