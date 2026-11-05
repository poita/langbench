/// Command-line front end: reads a program on stdin, prints the final machine state.
module main;

import std.stdio : stderr, stdin, stdout;
import chip8;

int main()
{
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(1 << 16))
        raw ~= chunk;

    Program prog;
    try
        prog = parseProgram(cast(const(char)[]) raw);
    catch (ParseException e)
    {
        stderr.writeln("chip8: ", e.msg);
        return 2;
    }

    auto machine = makeMachine(prog.rom);
    run(machine, prog.cycles, prog.events);
    stdout.rawWrite(render(machine));
    return 0;
}
