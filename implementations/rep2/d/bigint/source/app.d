/// Command-line front end: reads queries from stdin, writes results to stdout.
module app;

import bigint.query : evaluateAll;
import std.stdio : stdin, stdout;

int main()
{
    // Read all of stdin.
    char[] input;
    auto chunk = new char[1 << 20];
    for (;;)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        input ~= got;
    }

    stdout.rawWrite(evaluateAll(input));
    stdout.flush();
    return 0;
}
