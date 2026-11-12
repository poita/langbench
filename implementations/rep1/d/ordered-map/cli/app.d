/// Command-line front end: reads a command script on stdin, writes replies to stdout.
module app;

import orderedmap.commands : Interpreter;

import std.array : appender;
import std.exception : assumeUnique;
import std.stdio : stderr, stdin, stdout;

int main()
{
    // Read all of stdin.
    auto buf = appender!(ubyte[]);
    buf.reserve(1 << 20);
    foreach (chunk; stdin.byChunk(1 << 20))
        buf.put(chunk);
    immutable input = cast(string) assumeUnique(buf[]);

    auto output = appender!(char[]);
    output.reserve(1 << 20);

    Interpreter interp;
    int status = 0;
    try
        interp.run(input, output);
    catch (Exception e)
    {
        stderr.writefln("ordered-map: %s", e.msg);
        status = 1;
    }
    // Replies produced before any error are still delivered.
    stdout.rawWrite(output[]);
    stdout.flush();
    return status;
}
