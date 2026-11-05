/// Command-line front end: reads a SQL script on stdin, executes it and
/// prints the result of every SELECT (see README.md).
module main;

import std.array : Appender;
import std.stdio : stdin, stdout;
import minisql;

int main()
{
    Appender!(char[]) input;
    auto buf = new ubyte[1 << 16];
    for (;;)
    {
        auto got = stdin.rawRead(buf);
        if (got.length == 0)
            break;
        input.put(cast(const(char)[]) got);
    }
    auto script = cast(string) input[].idup;
    auto db = new Database;
    stdout.rawWrite(db.run(script));
    return 0;
}
