module tests.test_display;

import chip8;
import tests.helpers;

@("sprite wraps horizontally and vertically (spec example 2)")
unittest
{
    auto m = runCode([0x6a3e, 0x6b1e, 0x6000, 0xf029, 0xdab5, 0xdab5], 5);
    assert(m.pc == 0x20a && m.v[15] == 0);
    auto r = m.display.render();
    assert(r[0 .. 64] == ".#............................................................#.");
    assert(r[65 .. 129] == ".#............................................................#.");
    assert(r[130 .. 194] == "##............................................................##");
    assert(m.display[62, 30] && m.display[63, 30] && m.display[0, 30] && !m.display[2, 30]);

    m = runCode([0x6a3e, 0x6b1e, 0x6000, 0xf029, 0xdab5, 0xdab5], 6);
    assert(m.v[15] == 1 && m.pc == 0x20c);
    foreach (w; m.display.rows) assert(w == 0);
}

@("clear and zero-height sprites")
unittest
{
    auto m = runCode([0x6001, 0xf029, 0xd005, 0x00e0], 4);
    foreach (w; m.display.rows) assert(w == 0);
    m = runCode([0x6fff, 0xd000], 2);
    assert(m.v[15] == 0);
}

@("Display.xorByte reports collisions and handles sx = 0")
unittest
{
    Display d;
    assert(!d.xorByte(0, 0, 0x80));
    assert(d[0, 0]);
    assert(d.xorByte(0, 0, 0x80));
    assert(!d[0, 0]);
    assert(!d.xorByte(60, 33, 0xff)); // row 33 wraps to 1
    assert(d[60, 1] && d[3, 1] && !d[4, 1]);
}
