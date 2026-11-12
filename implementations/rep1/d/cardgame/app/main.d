/// Command-line tool: reads a Spiremark match file on stdin, writes the event log to stdout.
module main;

import std.stdio : stdin, stdout, File;
import std.file : read;
import std.array : appender;
import cardgame.session : runMatch;

int main()
{
    auto buf = appender!(ubyte[])();
    foreach (chunk; stdin.byChunk(1 << 16)) buf ~= chunk;
    auto input = cast(string) buf.data.idup;
    auto output = runMatch(input, (string path) => cast(string) read(path));
    stdout.rawWrite(output);
    stdout.flush();
    return 0;
}
