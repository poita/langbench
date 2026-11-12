/**
 * Command-line tool: reads one JSON document from stdin and prints its
 * canonical serialization, or `invalid` if it is not a valid document.
 * The exit code is 0 in both cases.
 */
module app;

import std.array : appender;
import std.stdio : stdin, stdout;

import jsoncanon;

/// Reads all of stdin.
ubyte[] readAll()
{
    auto buf = appender!(ubyte[]);
    ubyte[1 << 16] chunk;
    while (true)
    {
        auto got = stdin.rawRead(chunk[]);
        if (got.length == 0)
            break;
        buf.put(got);
    }
    return buf.data;
}

int main()
{
    auto input = readAll();
    auto out_ = appender!(char[]);
    try
    {
        auto doc = parse(input);
        writeCanonical(out_, doc);
    }
    catch (JsonException)
    {
        out_.clear();
        out_.put("invalid");
    }
    out_.put('\n');
    stdout.rawWrite(out_.data);
    stdout.flush();
    return 0;
}
