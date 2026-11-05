/// Command-line front end: reads a match file on stdin, writes the log on stdout.
module app.main;

import std.file : readText;
import std.stdio : stdin, stdout;

import cardgame.match : simulate;

int main()
{
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(1 << 16))
        raw ~= chunk;
    immutable input = cast(string) raw.idup;
    immutable result = simulate(input, (string path) => readText(path));
    stdout.rawWrite(result);
    return 0;
}
