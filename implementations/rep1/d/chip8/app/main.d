/// Command-line front end: reads the program from stdin, writes the final state to stdout.
module main;

import std.stdio : stdin, stdout, stderr, writeln;
import std.array : appender;
import chip8;

int main()
{
    auto text = appender!(char[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        text ~= cast(const(char)[]) chunk;

    Program prog;
    try
        prog = parseProgram(text[]);
    catch (InputException e)
    {
        stderr.writeln("chip8: invalid input: ", e.msg);
        return 1;
    }

    Machine m;
    m.reset();
    m.loadRom(prog.rom);
    m.run(prog.cycles, prog.events);

    stdout.rawWrite(formatState(m));
    stdout.flush();
    return 0;
}
