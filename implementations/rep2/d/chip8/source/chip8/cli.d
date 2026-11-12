/// The command-line driver, written as a function over text so it is testable.
module chip8.cli;

import chip8.input;
import chip8.keys;
import chip8.machine;
import chip8.output;

/**
 * Runs the program described by `text` (see `chip8.input`) and returns the
 * report described in `chip8.output`.
 * Throws: `ParseException` if `text` is malformed.
 */
string simulate(scope const(char)[] text) @safe pure
{
    auto prog = parseProgram(text);
    auto machine = Machine(prog.rom);
    auto schedule = KeySchedule(prog.events);
    machine.run(prog.cycles, schedule);
    return renderState(machine);
}

@safe pure unittest // spec example 1
{
    import std.string : splitLines;
    auto lines = simulate("60ff7001610180141208\n6\n").splitLines;
    assert(lines.length == 34);
    assert(lines[32] == "PC=0208 I=0000 SP=0 DT=00 ST=00");
    assert(lines[33] == "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00");
}

@safe pure unittest // spec example 3
{
    import std.string : splitLines;
    auto lines = simulate("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300").splitLines;
    assert(lines[32] == "PC=021e I=0000 SP=0 DT=07 ST=00");
    assert(lines[33] == "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00");
}

@safe pure unittest // spec example 2
{
    import std.string : splitLines;
    auto lines = simulate("6a3e6b1e6000f029dab5dab5\n5\n").splitLines;
    assert(lines[0] == ".#............................................................#.");
    assert(lines[2] == "##............................................................##");
    assert(lines[30] == "##............................................................##");
    assert(lines[32] == "PC=020a I=0050 SP=0 DT=00 ST=00");
}
