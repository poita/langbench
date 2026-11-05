/// Command-line front end: reads queries from stdin, writes results to stdout.
module app;

import std.stdio : stdin, stdout;
import bigint.queries : evaluateQueries;

int main()
{
    // Read all of stdin in bulk.
    char[] input;
    auto buf = new char[1 << 20];
    for (;;)
    {
        auto got = stdin.rawRead(buf[0 .. buf.length]);
        if (got.length == 0)
            break;
        input ~= got;
    }
    auto output = evaluateQueries(input);
    stdout.rawWrite(output);
    stdout.flush();
    return 0;
}
