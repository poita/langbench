/// Command-line front end: reads a registry and root manifest on stdin, prints the resolution.
module main;

import core.stdc.stdio : fwrite, stdout;
import std.array : appender;
import std.exception : assumeUnique;
import std.stdio : stdin;
import depresolve;

int main()
{
    auto buf = appender!(ubyte[])();
    ubyte[65_536] chunk;
    while (true)
    {
        auto got = stdin.rawRead(chunk[]);
        if (got.length == 0)
            break;
        buf ~= got;
    }
    const text = cast(string) assumeUnique(buf[]);
    const output = resolveText(text);
    fwrite(output.ptr, 1, output.length, stdout);
    return 0;
}
