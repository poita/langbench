/// Command-line front end: reads commands on stdin, writes results on stdout.
module app;

import std.stdio : stdin, stdout;
import webhooks.commands : processInput;
import webhooks.outbuf : OutBuf;

int main()
{
    // Read all of stdin in large chunks.
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

    OutBuf output;
    processInput(input[0 .. used], output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
