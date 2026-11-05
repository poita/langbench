/// Command-line front end: reads a program on stdin, writes the report on stdout.
module main;

import std.stdio : stderr, stdin, stdout, writeln;
import chip8;

int main()
{
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(64 * 1024))
        raw ~= chunk;

    try
    {
        auto prog = parseProgram(cast(const(char)[]) raw);
        auto m = Machine.create();
        m.loadRom(prog.rom);
        run(m, prog.cycles, prog.events);
        stdout.rawWrite(formatState(m));
        stdout.flush();
    }
    catch (Exception e)
    {
        stderr.writeln("chip8: ", e.msg);
        return 1;
    }
    return 0;
}
