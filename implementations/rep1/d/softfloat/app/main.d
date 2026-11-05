/// Command-line front end: reads operations on stdin, writes results on stdout.
module main;

import std.stdio : stdin, stdout;
import softfloat.io : processBatch;

int main()
{
    ubyte[] input;
    size_t used = 0;
    input.length = 1 << 16;
    for (;;)
    {
        if (used == input.length)
            input.length = input.length * 2;
        auto got = stdin.rawRead(input[used .. $]);
        if (got.length == 0)
            break;
        used += got.length;
    }
    auto output = processBatch(input[0 .. used]);
    stdout.rawWrite(output);
    stdout.flush();
    return 0;
}
