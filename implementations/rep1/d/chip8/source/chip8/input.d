/// Parsing of the textual input format (ROM hex, cycle count, key schedule).
module chip8.input;

import chip8.constants : maxRomSize;
import chip8.machine : KeyEvent;

/// Thrown when the input text is malformed.
class InputException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A parsed program: ROM image, cycle budget and key schedule.
struct Program
{
    /// ROM bytes.
    ubyte[] rom;
    /// Number of cycles to execute.
    ulong cycles;
    /// Key events in input order.
    KeyEvent[] events;
}

private int hexValue(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decode a hex string (two digits per byte) into bytes.
ubyte[] parseHex(const(char)[] s) pure @safe
{
    if (s.length % 2 != 0)
        throw new InputException("odd number of hex digits");
    auto r = new ubyte[s.length / 2];
    foreach (k; 0 .. r.length)
    {
        immutable h = hexValue(s[2 * k]), l = hexValue(s[2 * k + 1]);
        if (h < 0 || l < 0)
            throw new InputException("invalid hex digit");
        r[k] = cast(ubyte)(h << 4 | l);
    }
    return r;
}

/// Parse an unsigned decimal integer.
ulong parseDecimal(const(char)[] s) pure @safe
{
    if (s.length == 0)
        throw new InputException("empty number");
    ulong r = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new InputException("invalid decimal digit");
        r = r * 10 + (c - '0');
    }
    return r;
}

/// Parse a key schedule: events `<cycle>:<mask>` separated by spaces.
KeyEvent[] parseKeySchedule(const(char)[] s) pure @safe
{
    KeyEvent[] events;
    size_t pos = 0;
    while (pos < s.length)
    {
        size_t end = pos;
        while (end < s.length && s[end] != ' ')
            end++;
        auto tok = s[pos .. end];
        size_t colon = 0;
        while (colon < tok.length && tok[colon] != ':')
            colon++;
        if (colon == tok.length)
            throw new InputException("key event without ':'");
        auto maskStr = tok[colon + 1 .. $];
        if (maskStr.length != 4)
            throw new InputException("key mask must have 4 hex digits");
        uint mask = 0;
        foreach (c; maskStr)
        {
            immutable d = hexValue(c);
            if (d < 0)
                throw new InputException("invalid hex digit in key mask");
            mask = mask << 4 | d;
        }
        events ~= KeyEvent(parseDecimal(tok[0 .. colon]), cast(ushort) mask);
        pos = end + 1;
    }
    return events;
}

/// Parse the full input text (see SPEC.md).
Program parseProgram(const(char)[] text) pure @safe
{
    // Split into at most three lines, tolerating a missing final newline and CRLF.
    const(char)[][3] lines;
    size_t n = 0;
    size_t pos = 0;
    while (pos < text.length && n < 3)
    {
        size_t end = pos;
        while (end < text.length && text[end] != '\n')
            end++;
        auto line = text[pos .. end];
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        lines[n++] = line;
        pos = end + 1;
    }
    if (n < 2)
        throw new InputException("expected a ROM line and a cycle-count line");

    Program p;
    p.rom = parseHex(lines[0]);
    if (p.rom.length == 0 || p.rom.length > maxRomSize)
        throw new InputException("ROM size out of range");
    p.cycles = parseDecimal(lines[1]);
    if (n == 3)
        p.events = parseKeySchedule(lines[2]);
    return p;
}
