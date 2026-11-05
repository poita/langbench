/++
Rendering of a machine's display and registers as the 34-line text report.
+/
module chip8.output;

import chip8.machine;

private immutable hexDigits = "0123456789abcdef";

private char[] putHex(return char[] dst, uint value, uint digits) pure nothrow @nogc @safe
{
    foreach (k; 0 .. digits)
        dst[k] = hexDigits[(value >> (4 * (digits - 1 - k))) & 0xF];
    return dst[digits .. $];
}

/++
Format the display (32 rows of 64 `#`/`.`), the `PC=… I=… SP=… DT=… ST=…`
line and the `V=…` line. Every line ends with `\n`.
+/
string formatState(const ref Machine m) pure nothrow @safe
{
    auto buf = new char[displayHeight * (displayWidth + 1) + 128];
    size_t n = 0;
    foreach (row; m.display)
    {
        foreach (x; 0 .. displayWidth)
            buf[n++] = ((row >> (displayWidth - 1 - x)) & 1) ? '#' : '.';
        buf[n++] = '\n';
    }

    void put(scope const(char)[] s) { buf[n .. n + s.length] = s[]; n += s.length; }
    void hex(uint value, uint digits) { putHex(buf[n .. $], value, digits); n += digits; }

    put("PC="); hex(m.pc, 4);
    put(" I="); hex(m.i, 4);
    put(" SP=");
    if (m.sp >= 100) buf[n++] = cast(char)('0' + m.sp / 100);
    if (m.sp >= 10) buf[n++] = cast(char)('0' + (m.sp / 10) % 10);
    buf[n++] = cast(char)('0' + m.sp % 10);
    put(" DT="); hex(m.dt, 2);
    put(" ST="); hex(m.st, 2);
    put("\nV=");
    foreach (k; 0 .. 16)
    {
        if (k) buf[n++] = ' ';
        hex(m.v[k], 2);
    }
    buf[n++] = '\n';
    return (() @trusted => cast(string) buf[0 .. n])();
}

///
unittest
{
    import std.algorithm.searching : startsWith;
    auto m = Machine.create();
    auto s = formatState(m);
    assert(s.length == 32 * 65 + "PC=0200 I=0000 SP=0 DT=00 ST=00\n".length + 2 + 16 * 3);
    assert(s.startsWith("................................................................\n"));
    assert(s[32 * 65 .. $] ==
        "PC=0200 I=0000 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n");
}
