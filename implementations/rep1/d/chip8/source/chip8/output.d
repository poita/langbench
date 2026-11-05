/// Rendering of the final machine state as text.
module chip8.output;

import chip8.constants : displayHeight, displayWidth;
import chip8.machine : Machine;

private immutable hexDigits = "0123456789abcdef";

private size_t putHex(char[] buf, size_t o, uint value, uint digits) pure nothrow @safe @nogc
{
    foreach_reverse (k; 0 .. digits)
        buf[o++] = hexDigits[(value >> (4 * k)) & 0xF];
    return o;
}

private size_t putStr(char[] buf, size_t o, string s) pure nothrow @safe @nogc
{
    buf[o .. o + s.length] = s[];
    return o + s.length;
}

private size_t putDecimal(char[] buf, size_t o, uint value) pure nothrow @safe @nogc
{
    char[10] tmp;
    size_t n = 0;
    do
    {
        tmp[n++] = cast(char)('0' + value % 10);
        value /= 10;
    } while (value);
    while (n)
        buf[o++] = tmp[--n];
    return o;
}

/++
    Format the machine state as the 34 output lines described in SPEC.md:
    32 display rows, the `PC=... I=...` line and the `V=...` line.
+/
char[] formatState(const ref Machine m) pure nothrow @safe
{
    enum displayBytes = displayHeight * (displayWidth + 1);
    auto buf = new char[displayBytes + 128];
    m.display.renderInto(buf);
    size_t o = displayBytes;
    o = putStr(buf, o, "PC=");
    o = putHex(buf, o, m.pc, 4);
    o = putStr(buf, o, " I=");
    o = putHex(buf, o, m.i, 4);
    o = putStr(buf, o, " SP=");
    o = putDecimal(buf, o, m.sp);
    o = putStr(buf, o, " DT=");
    o = putHex(buf, o, m.dt, 2);
    o = putStr(buf, o, " ST=");
    o = putHex(buf, o, m.st, 2);
    buf[o++] = '\n';
    o = putStr(buf, o, "V=");
    foreach (k, r; m.v)
    {
        if (k) buf[o++] = ' ';
        o = putHex(buf, o, r, 2);
    }
    buf[o++] = '\n';
    return buf[0 .. o];
}
