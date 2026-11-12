/// Parsing of the textual program format.
module chip8.input;

import chip8.keys;
import chip8.machine : maxRomSize;

/// Thrown when the input text is not in the expected format.
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
    /// ROM bytes, loaded at `0x200`.
    ubyte[] rom;
    /// Number of cycles to execute.
    ulong cycles;
    /// Key events.
    KeyEvent[] events;
}

private uint hexDigit(char c) @safe pure
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    throw new ParseException("invalid hex digit");
}

private ulong parseDecimal(scope const(char)[] s) @safe pure
{
    if (s.length == 0 || s.length > 19)
        throw new ParseException("invalid decimal number");
    ulong r;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid decimal number");
        r = r * 10 + (c - '0');
    }
    return r;
}

/// Decodes a string of hex digit pairs into bytes.
ubyte[] parseHexBytes(scope const(char)[] s) @safe pure
{
    if (s.length % 2 != 0)
        throw new ParseException("odd number of hex digits");
    auto r = new ubyte[s.length / 2];
    foreach (k, ref b; r)
        b = cast(ubyte)(hexDigit(s[2 * k]) * 16 + hexDigit(s[2 * k + 1]));
    return r;
}

/// Parses a key schedule line such as `"9:0300 12:0000"`; an empty line gives no events.
KeyEvent[] parseKeySchedule(scope const(char)[] line) @safe pure
{
    KeyEvent[] events;
    size_t pos;
    while (pos < line.length)
    {
        size_t end = pos;
        while (end < line.length && line[end] != ' ')
            ++end;
        const tok = line[pos .. end];
        size_t colon = 0;
        while (colon < tok.length && tok[colon] != ':')
            ++colon;
        if (colon == tok.length || tok.length - colon - 1 != 4)
            throw new ParseException("malformed key event");
        const cycle = parseDecimal(tok[0 .. colon]);
        ushort mask;
        foreach (c; tok[colon + 1 .. $])
            mask = cast(ushort)(mask * 16 + hexDigit(c));
        if (events.length && events[$ - 1].cycle >= cycle)
            throw new ParseException("key events not strictly increasing");
        events ~= KeyEvent(cycle, mask);
        pos = end + 1;
    }
    return events;
}

/**
 * Parses the three-line program format: ROM hex, decimal cycle count and an
 * optional key schedule.
 * Throws: `ParseException` on malformed input.
 */
Program parseProgram(scope const(char)[] text) @safe pure
{
    string[3] lines;
    size_t count;
    size_t start;
    foreach (k; 0 .. text.length + 1)
    {
        if (k == text.length || text[k] == '\n')
        {
            if (k == text.length && start == k)
                break; // no trailing partial line
            if (count == 3)
            {
                if (k > start)
                    throw new ParseException("unexpected trailing data");
                break;
            }
            auto l = text[start .. k];
            if (l.length && l[$ - 1] == '\r')
                l = l[0 .. $ - 1];
            lines[count++] = l.idup;
            start = k + 1;
        }
    }
    if (count < 2)
        throw new ParseException("expected ROM line and cycle count line");

    Program p;
    p.rom = parseHexBytes(lines[0]);
    if (p.rom.length == 0 || p.rom.length > maxRomSize)
        throw new ParseException("ROM must be 1..3584 bytes");
    p.cycles = parseDecimal(lines[1]);
    p.events = parseKeySchedule(lines[2]);
    return p;
}

@safe pure unittest
{
    auto p = parseProgram("60ff\n12\n9:0300 12:0000\n");
    assert(p.rom == [0x60, 0xff] && p.cycles == 12);
    assert(p.events == [KeyEvent(9, 0x300), KeyEvent(12, 0)]);
}

@safe pure unittest // optional third line and trailing newline
{
    foreach (t; ["60ff\n12", "60ff\n12\n", "60ff\n12\n\n"])
    {
        auto p = parseProgram(t);
        assert(p.cycles == 12 && p.events.length == 0);
    }
    assert(parseProgram("00\n4000000000").cycles == 4_000_000_000UL);
}

@safe pure unittest // malformed input is rejected
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseProgram(""));
    assertThrown!ParseException(parseProgram("60f\n1"));
    assertThrown!ParseException(parseProgram("60zz\n1"));
    assertThrown!ParseException(parseProgram("\n1"));
    assertThrown!ParseException(parseProgram("60ff\nx"));
    assertThrown!ParseException(parseProgram("60ff\n1\n3:00"));
    assertThrown!ParseException(parseProgram("60ff\n1\n3:0000 3:0000"));
}
