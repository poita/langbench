/// depresolve command-line tool: reads a registry and root manifest on
/// standard input, prints the resolution on standard output.
module app;

import std.stdio : stdin, stdout;

import depresolve;

/// Reads all of standard input.
private string readAll()
{
    import std.array : appender;

    auto app = appender!(ubyte[]);
    ubyte[1 << 16] buf;
    while (true)
    {
        auto got = stdin.rawRead(buf[]);
        if (got.length == 0)
            break;
        app ~= got;
    }
    return cast(string) app.data;
}

int main()
{
    auto problem = parseProblem(readAll());
    auto result = resolve(problem);
    stdout.write(formatResolution(result));
    return 0;
}
