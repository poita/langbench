/// Command-line front end: read commands on stdin, write events on stdout.
module main;

import std.stdio : stdin, stdout;
import orderbook.driver : processStream;
import orderbook.outbuf : OutBuf;

/// Read all of standard input into one buffer.
private char[] readAll()
{
    char[] buf = new char[](1 << 20);
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(buf[len .. $]);
        if (got.length == 0)
            break;
        len += got.length;
    }
    return buf[0 .. len];
}

int main()
{
    auto input = readAll();
    OutBuf output;
    processStream(input, output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
