/// Command-line front end: reads a filter line and a JSON document on stdin, prints each result.
module main;

import std.stdio : stdin, stdout, stderr;
import std.exception : assumeUnique;

import jq;

// Reduce collector churn: queries that rebuild large containers (e.g. `reduce ... (. + [x])`)
// allocate a lot of short-lived memory.
extern (C) __gshared string[] rt_options = ["gcopt=minPoolSize:128"];

int main()
{
    char[] data;
    {
        enum chunk = 1 << 16;
        auto buf = new ubyte[](chunk);
        while (true)
        {
            auto got = stdin.rawRead(buf);
            if (got.length == 0)
                break;
            data ~= cast(char[]) got;
        }
    }
    auto out_ = stdout;
    string problem;
    immutable ok = runSpecInput(assumeUnique(data), (const(char)[] s) { out_.rawWrite(s); }, problem);
    out_.flush();
    if (!ok)
        stderr.writeln("jq: ", problem);
    return 0;
}
