/// Command-line front end: reads queries from stdin, writes answers to stdout.
module main;

import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import chessperft.query : answerAll;

int main()
{
    auto input = appender!(char[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        input.put(cast(const(char)[]) chunk);
    try
    {
        stdout.rawWrite(answerAll(input.data));
    }
    catch (Exception e)
    {
        stderr.writeln("chess-perft: ", e.msg);
        return 1;
    }
    return 0;
}
