/// Unit tests for chip8.input.
module tests.test_input;

import std.exception : assertThrown;
import chip8;

unittest // example 1 style input
{
    auto p = parseProgram("60ff7001\n6\n");
    assert(p.rom == [0x60, 0xff, 0x70, 0x01]);
    assert(p.cycles == 6);
    assert(p.events.length == 0);
}

unittest // key schedule, with and without trailing newline
{
    auto p = parseProgram("00e0\n14\n9:0300 12:0000");
    assert(p.events == [KeyEvent(9, 0x0300), KeyEvent(12, 0)]);
    auto q = parseProgram("00e0\n14\n\n");
    assert(q.events.length == 0);
}

unittest // large cycle count
{
    assert(parseProgram("00e0\n4000000000").cycles == 4_000_000_000UL);
}

unittest // malformed input is rejected
{
    assertThrown!ParseException(parseProgram("0\n1\n"));
    assertThrown!ParseException(parseProgram("zz\n1\n"));
    assertThrown!ParseException(parseProgram("00e0\n"));
    assertThrown!ParseException(parseProgram("00e0\nx\n"));
    assertThrown!ParseException(parseProgram("00e0\n5\n3:00\n"));
    assertThrown!ParseException(parseProgram("00e0\n5\n3:0001 3:0002\n"));
}

unittest // ROM size limits
{
    import std.array : replicate;
    assert(parseProgram("00".replicate(3584) ~ "\n1").rom.length == 3584);
    assertThrown!ParseException(parseProgram("00".replicate(3585) ~ "\n1"));
}
