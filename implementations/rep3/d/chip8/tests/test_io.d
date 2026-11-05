/// Tests for chip8.input and chip8.output, plus end-to-end examples.
module test_io;

import std.exception : assertThrown;
import chip8;

private string simulate(string text)
{
    auto prog = parseProgram(text);
    auto m = Machine.create();
    m.loadRom(prog.rom);
    run(m, prog.cycles, prog.events);
    return formatState(m);
}

unittest // parse: optional newline and key schedule
{
    auto p = parseProgram("00e0\n0");
    assert(p.rom == [0x00, 0xe0] && p.cycles == 0 && p.events.length == 0);
    p = parseProgram("00e0\n7\n\n");
    assert(p.events.length == 0);
    p = parseProgram("00e0\n4000000000\n0:ffff 4000000000:0000");
    assert(p.cycles == 4_000_000_000UL && p.events.length == 2 && p.events[0].mask == 0xffff);
}

unittest // parse errors
{
    assertThrown!ParseException(parseProgram("0\n1\n"));
    assertThrown!ParseException(parseProgram("zz\n1\n"));
    assertThrown!ParseException(parseProgram("00\n"));
    assertThrown!ParseException(parseProgram("00\n4000000001\n"));
    assertThrown!ParseException(parseProgram("00\n5\n2:0001 2:0000\n"));
    assertThrown!ParseException(parseProgram("00\n5\n2:001\n"));
}

unittest // spec example 1
{
    auto s = simulate("60ff7001610180141208\n6\n");
    assert(s[32 * 65 .. $] ==
        "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n");
}

unittest // spec example 2
{
    auto s = simulate("6a3e6b1e6000f029dab5dab5\n5\n");
    assert(s[0 .. 65] == ".#............................................................#.\n");
    assert(s[2 * 65 .. 3 * 65] == "##............................................................##\n");
    assert(s[30 * 65 .. 31 * 65] == "##............................................................##\n");
    assert(s[32 * 65 .. $] ==
        "PC=020a I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00\n");
}

unittest // spec example 3
{
    auto s = simulate("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n");
    assert(s[32 * 65 .. $] ==
        "PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n");
}

unittest // stack pointer is printed without padding, up to 16
{
    auto m = Machine.create();
    m.sp = 16;
    import std.algorithm.searching : canFind;
    assert(formatState(m).canFind(" SP=16 "));
}
