/// Formatting of the final machine report.
module chip8.output;

import chip8.machine : Machine;

private immutable hexDigits = "0123456789abcdef";

private void putHex(ref char[] buf, uint value, uint digits) @safe pure nothrow
{
    foreach_reverse (d; 0 .. digits)
        buf ~= hexDigits[(value >> (4 * d)) & 0xF];
}

/// Format the 34-line report: display, status line, register line.
string report(ref const Machine m) @safe pure
{
    import std.conv : to;

    char[] buf;
    buf ~= m.display.render();
    buf ~= "PC=";  putHex(buf, m.pc, 4);
    buf ~= " I=";  putHex(buf, m.i, 4);
    buf ~= " SP="; buf ~= m.sp.to!string;
    buf ~= " DT="; putHex(buf, m.dt, 2);
    buf ~= " ST="; putHex(buf, m.st, 2);
    buf ~= "\nV=";
    foreach (k, r; m.v)
    {
        if (k) buf ~= ' ';
        putHex(buf, r, 2);
    }
    buf ~= '\n';
    return (() @trusted => cast(string) buf)();
}

@safe pure unittest
{
    import std.algorithm.searching : count;
    auto m = Machine([0x00, 0x00]);
    m.i = 0xBEEF;
    m.v[15] = 0xA;
    auto r = report(m);
    assert(r.count('\n') == 34);
    assert(r[32 * 65 .. $] ==
        "PC=0200 I=beef SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0a\n");
}
