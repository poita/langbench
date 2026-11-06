/++
    Parsing of the textual program format.

    The format has up to three lines: the ROM as lowercase hex, the cycle
    budget in decimal, and an optional key schedule of `cycle:mask` events.
+/
module chip8.input;

import chip8.machine : KeyEvent, Machine, memorySize, romBase;

/// Thrown by $(LREF parseProgram) for malformed input.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A parsed program: ROM image, cycle budget and key schedule.
struct Program
{
    /// ROM bytes, to be loaded at `romBase`.
    ubyte[] rom;
    /// Number of instruction cycles to execute.
    ulong cycles;
    /// Key events in strictly increasing cycle order.
    KeyEvent[] events;
}

/// Value of a hex digit, or -1 if `c` is not a hex digit (either case).
int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decodes a hex string (two digits per byte) into bytes.
ubyte[] parseHex(const(char)[] s) @safe pure
{
    if (s.length % 2 != 0)
        throw new ParseException("hex string has odd length");
    auto bytes = new ubyte[s.length / 2];
    foreach (k; 0 .. bytes.length)
    {
        immutable hi = hexValue(s[2 * k]);
        immutable lo = hexValue(s[2 * k + 1]);
        if (hi < 0 || lo < 0)
            throw new ParseException("invalid hex digit in ROM");
        bytes[k] = cast(ubyte)(hi << 4 | lo);
    }
    return bytes;
}

private ulong parseDecimal(const(char)[] s) @safe pure
{
    if (s.length == 0 || s.length > 19)
        throw new ParseException("invalid decimal number");
    ulong v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid decimal number");
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Parses a key schedule such as `"9:0300 20:0000"` (may be empty).
KeyEvent[] parseKeySchedule(const(char)[] s) @safe pure
{
    KeyEvent[] events;
    size_t pos = 0;
    while (pos < s.length)
    {
        size_t end = pos;
        while (end < s.length && s[end] != ' ') ++end;
        auto tok = s[pos .. end];
        size_t colon = 0;
        while (colon < tok.length && tok[colon] != ':') ++colon;
        if (colon == tok.length || tok.length - colon - 1 != 4)
            throw new ParseException("malformed key event");
        immutable cycle = parseDecimal(tok[0 .. colon]);
        uint mask = 0;
        foreach (c; tok[colon + 1 .. $])
        {
            immutable d = hexValue(c);
            if (d < 0) throw new ParseException("invalid key mask");
            mask = mask << 4 | d;
        }
        if (events.length && cycle <= events[$ - 1].cycle)
            throw new ParseException("key events not strictly increasing");
        events ~= KeyEvent(cycle, cast(ushort) mask);
        pos = end + 1;
    }
    return events;
}

/// Parses the complete input text (ROM, cycles, optional key schedule).
Program parseProgram(const(char)[] text) @safe pure
{
    const(char)[][3] lines;
    size_t n = 0;
    size_t pos = 0;
    while (pos <= text.length && n < 3)
    {
        size_t end = pos;
        while (end < text.length && text[end] != '\n') ++end;
        lines[n++] = text[pos .. end];
        pos = end + 1;
    }
    if (n < 2)
        throw new ParseException("expected ROM and cycle lines");
    Program p;
    p.rom = parseHex(lines[0]);
    if (p.rom.length == 0 || p.rom.length > memorySize - romBase)
        throw new ParseException("ROM size out of range");
    p.cycles = parseDecimal(lines[1]);
    if (n == 3)
        p.events = parseKeySchedule(lines[2]);
    return p;
}
