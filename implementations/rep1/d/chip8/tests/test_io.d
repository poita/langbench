module tests.test_io;

import std.exception : assertThrown;
import chip8;

@("parseProgram reads rom, cycles and key schedule")
unittest
{
    auto p = parseProgram("60ff\n12\n3:0001 9:ffff\n");
    assert(p.rom == [0x60, 0xff]);
    assert(p.cycles == 12);
    assert(p.events == [KeyEvent(3, 1), KeyEvent(9, 0xffff)]);
}

@("optional third line and trailing newline")
unittest
{
    assert(parseProgram("00\n0").events.length == 0);
    assert(parseProgram("00\n4000000000\n\n").cycles == 4_000_000_000UL);
    assert(parseProgram("00\n1\n").events.length == 0);
}

@("malformed input is rejected")
unittest
{
    assertThrown!InputException(parseProgram("0\n1"));
    assertThrown!InputException(parseProgram("zz\n1"));
    assertThrown!InputException(parseProgram("00"));
    assertThrown!InputException(parseProgram("00\n1\n3-0001"));
}

@("formatState produces 34 lines in the specified format")
unittest
{
    Machine m;
    m.reset();
    m.pc = 0x20a;
    m.i = 0x50;
    m.sp = 16;
    m.dt = 7;
    m.v[1] = 0xab;
    auto s = formatState(m);
    import std.string : splitLines;
    auto lines = splitLines(cast(string) s.idup);
    assert(lines.length == 34);
    assert(lines[0] == "................................................................");
    assert(lines[32] == "PC=020a I=0050 SP=16 DT=07 ST=00");
    assert(lines[33] == "V=00 ab 00 00 00 00 00 00 00 00 00 00 00 00 00 00");
    assert(s[$ - 1] == '\n');
}

@("RNG matches the spec's first states")
unittest
{
    uint s = rngSeed;
    s = rngNext(s); assert(s == 0x0b719151 && rngByte(s) == 0x71);
    s = rngNext(s); assert(s == 0x6f47bdb6 && rngByte(s) == 0x47);
    s = rngNext(s); assert(s == 0x2e1d6ab7 && rngByte(s) == 0x1d);
    Rng r;
    assert(r.next() == 0x71);
}
