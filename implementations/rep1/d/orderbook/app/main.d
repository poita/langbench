/// Command-line front end: reads commands on stdin, writes events to stdout.
module app.main;

import std.array : appender;
import std.exception : assumeUnique;
import std.stdio : stderr, stdin, stdout;

import orderbook;

/// Read all of standard input.
string readAll()
{
    auto data = appender!(ubyte[]);
    ubyte[] chunk = new ubyte[1 << 20];
    for (;;)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        data.put(got);
    }
    return cast(string) assumeUnique(data[]);
}

int main()
{
    auto input = readAll();
    auto writer = BufferedWriter(stdout);
    auto sink = textSink(writer);
    int status = 0;
    try
        processStream(new OrderBook, input, sink);
    catch (ProtocolException e)
    {
        stderr.writeln("orderbook: ", e.msg);
        status = 1;
    }
    writer.flush();
    return status;
}
