/// Command-line tool: reads a program on stdin, prints one type (or error) per declaration.
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;
import typeinfer;

private string readAll()
{
    auto buf = appender!(char[]);
    auto chunk = new char[1 << 20];
    while (true)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        buf.put(got);
    }
    return cast(string) buf.data;
}

int main()
{
    immutable source = readAll();
    auto output = appender!(char[]);
    string failure;
    runWithLargeStack({
        try
            new TypeChecker().format(source, output);
        catch (SyntaxError e)
            failure = e.msg;
    });
    stdout.rawWrite(output.data);
    stdout.flush();
    if (failure !is null)
    {
        stderr.writeln("typeinfer: syntax error: ", failure);
        return 1;
    }
    return 0;
}
