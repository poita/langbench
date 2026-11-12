/**
 * Command-line front end: reads a SQL script from standard input, executes it
 * and prints the result of every SELECT on standard output.
 */
module app;

import std.array : appender;
import std.stdio : stdin, stdout;

import minisql;

int main()
{
    // Read all of stdin as raw bytes.
    auto bytes = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        bytes.put(chunk);
    auto script = cast(string) bytes[].idup;

    auto db = new Database;
    db.runScript(script, (const(char)[] s) @trusted { stdout.rawWrite(s); });
    stdout.flush();
    return 0;
}
