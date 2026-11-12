/// Command-line front end: reads query lines on stdin, writes QR symbols as text on stdout.
module app;

import qrcode;
import std.stdio;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: qrcode < queries.txt > symbols.txt");
        stderr.writeln("each input line: <L|M|Q|H> <0..7|auto> <text>");
        return args[1] == "-h" || args[1] == "--help" ? 0 : 2;
    }

    ubyte[] input;
    foreach (chunk; stdin.byChunk(1 << 16))
        input ~= chunk;

    Query[] queries;
    try
        queries = parseQueries(input);
    catch (QueryFormatException e)
    {
        stderr.writeln("qrcode: ", e.msg);
        return 1;
    }

    auto out_ = stdout.lockingTextWriter;
    foreach (i, q; queries)
    {
        try
            out_.put(renderQuery(q));
        catch (DataTooLongException e)
        {
            stderr.writefln("qrcode: query %s: %s", i + 1, e.msg);
            return 1;
        }
    }
    return 0;
}
