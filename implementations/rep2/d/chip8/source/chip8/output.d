/// Rendering of a machine's final state as text.
module chip8.output;

import std.array : appender;
import std.format : formattedWrite;

import chip8.display;
import chip8.machine;

/// Renders the 32 display rows, each 64 characters (`#` lit, `.` unlit) plus `\n`.
string renderDisplay(ref const Display d) @safe pure
{
    auto o = appender!string;
    o.reserve((Display.width + 1) * Display.height);
    foreach (y; 0 .. Display.height)
    {
        foreach (x; 0 .. Display.width)
            o.put(d[x, y] ? '#' : '.');
        o.put('\n');
    }
    return o.data;
}

/// Renders the `PC=... I=... SP=... DT=... ST=...` line and the `V=...` line.
string renderRegisters(ref const Machine m) @safe pure
{
    auto o = appender!string;
    o.formattedWrite("PC=%04x I=%04x SP=%d DT=%02x ST=%02x\nV=", m.pc, m.i, m.sp, m.dt, m.st);
    foreach (k, r; m.v)
    {
        if (k) o.put(' ');
        o.formattedWrite("%02x", r);
    }
    o.put('\n');
    return o.data;
}

/// Renders the full 34-line report: display, then registers.
string renderState(ref const Machine m) @safe pure
{
    return renderDisplay(m.display) ~ renderRegisters(m);
}

@safe pure unittest
{
    auto m = Machine([0x60, 0x01]);
    m.v[0xF] = 0xab;
    m.pc = 0x20a;
    m.i = 0x50;
    m.sp = 16;
    m.dt = 7;
    m.display.toggle(63, 31);
    const s = renderState(m);
    import std.algorithm : count;
    import std.string : splitLines;
    auto lines = s.splitLines;
    assert(lines.length == 34 && s[$ - 1] == '\n');
    assert(lines[31] == "................................................................".dup[0 .. 63] ~ "#");
    assert(lines[32] == "PC=020a I=0050 SP=16 DT=07 ST=00");
    assert(lines[33] == "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ab");
}
