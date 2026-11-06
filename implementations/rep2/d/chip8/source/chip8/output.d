/// Rendering of the machine state as the textual report.
module chip8.output;

import chip8.machine : Machine, displayHeight, displayWidth;

private immutable hexDigits = "0123456789abcdef";

/// Appends `value` as exactly `digits` lowercase hex digits.
private void putHex(ref char[] buf, uint value, uint digits) @safe pure nothrow
{
    foreach (k; 0 .. digits)
        buf ~= hexDigits[(value >> (4 * (digits - 1 - k))) & 0xF];
}

/// Appends `value` in decimal without padding.
private void putDecimal(ref char[] buf, uint value) @safe pure nothrow
{
    char[10] tmp;
    size_t k = tmp.length;
    do
    {
        tmp[--k] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    buf ~= tmp[k .. $];
}

/++
    Renders the 32 display rows (`#` lit, `.` unlit) followed by the
    `PC=... I=... SP=... DT=... ST=...` and `V=...` lines.

    Every line ends in `\n`; the result is exactly 34 lines, built in one buffer.
+/
string render(ref const Machine m) @trusted pure nothrow
{
    char[] buf;
    buf.reserve(displayHeight * (displayWidth + 1) + 128);
    foreach (y; 0 .. displayHeight)
    {
        immutable row = m.display[y];
        foreach (x; 0 .. displayWidth)
            buf ~= ((row >> (displayWidth - 1 - x)) & 1) ? '#' : '.';
        buf ~= '\n';
    }
    buf ~= "PC=";
    putHex(buf, m.pc, 4);
    buf ~= " I=";
    putHex(buf, m.i, 4);
    buf ~= " SP=";
    putDecimal(buf, m.sp);
    buf ~= " DT=";
    putHex(buf, m.dt, 2);
    buf ~= " ST=";
    putHex(buf, m.st, 2);
    buf ~= "\nV=";
    foreach (k; 0 .. 16)
    {
        if (k) buf ~= ' ';
        putHex(buf, m.v[k], 2);
    }
    buf ~= '\n';
    return cast(string) buf;
}
