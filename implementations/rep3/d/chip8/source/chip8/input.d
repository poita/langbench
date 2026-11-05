/++
Parsing of the textual program format: ROM hex, cycle count, key schedule.

---
<rom-hex>
<cycles>
<key-schedule>      (optional; events "<cycle>:<mask4hex>" separated by spaces)
---
+/
module chip8.input;

import chip8.cpu : KeyEvent;
import chip8.machine : maxRomSize;

/// Thrown by $(LREF parseProgram) on malformed input.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A parsed program: what to load, how long to run, and the key schedule.
struct Program
{
    /// ROM image, to be loaded at `0x200`.
    ubyte[] rom;
    /// Number of cycles to execute.
    ulong cycles;
    /// Key events in strictly increasing cycle order.
    KeyEvent[] events;
}

private int hexValue(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private ulong parseDecimal(scope const(char)[] s, ulong limit, string what) pure @safe
{
    if (s.length == 0)
        throw new ParseException("missing " ~ what);
    ulong value = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid " ~ what);
        value = value * 10 + (c - '0');
        if (value > limit)
            throw new ParseException(what ~ " out of range");
    }
    return value;
}

/// Convert a string of hex digit pairs to bytes.
ubyte[] parseHex(scope const(char)[] s) pure @safe
{
    if (s.length % 2 != 0)
        throw new ParseException("odd number of hex digits");
    auto bytes = new ubyte[s.length / 2];
    foreach (k, ref b; bytes)
    {
        immutable hi = hexValue(s[2 * k]);
        immutable lo = hexValue(s[2 * k + 1]);
        if (hi < 0 || lo < 0)
            throw new ParseException("invalid hex digit in ROM");
        b = cast(ubyte)(hi << 4 | lo);
    }
    return bytes;
}

/// Parse a key schedule such as `"9:0300 20:0000"`. An empty string gives no events.
KeyEvent[] parseKeySchedule(scope const(char)[] s, ulong maxCycle = ulong.max) pure @safe
{
    KeyEvent[] events;
    size_t pos = 0;
    while (pos < s.length)
    {
        size_t end = pos;
        while (end < s.length && s[end] != ' ')
            end++;
        auto token = s[pos .. end];
        size_t colon = 0;
        while (colon < token.length && token[colon] != ':')
            colon++;
        if (colon == token.length || token.length - colon - 1 != 4)
            throw new ParseException("malformed key event");
        immutable cycle = parseDecimal(token[0 .. colon], maxCycle, "event cycle");
        uint mask = 0;
        foreach (c; token[colon + 1 .. $])
        {
            immutable h = hexValue(c);
            if (h < 0)
                throw new ParseException("invalid key mask");
            mask = mask << 4 | h;
        }
        if (events.length && events[$ - 1].cycle >= cycle)
            throw new ParseException("key events not strictly increasing");
        events ~= KeyEvent(cycle, cast(ushort) mask);
        pos = end + 1;
    }
    return events;
}

/++
Parse a complete program from its text form. A trailing newline (and `\r`
before newlines) is accepted; the key-schedule line is optional.
+/
Program parseProgram(scope const(char)[] text) pure @safe
{
    const(char)[][3] lines;
    size_t count = 0;
    size_t start = 0;
    foreach (k; 0 .. text.length + 1)
    {
        if (k == text.length || text[k] == '\n')
        {
            if (k == text.length && start == k)
                break; // no data after the final newline
            auto line = text[start .. k];
            if (line.length && line[$ - 1] == '\r')
                line = line[0 .. $ - 1];
            if (count == 3)
                throw new ParseException("too many lines");
            lines[count++] = line;
            start = k + 1;
        }
    }
    if (count < 2)
        throw new ParseException("expected ROM and cycle count lines");

    Program p;
    if (lines[0].length < 2)
        throw new ParseException("empty ROM");
    if (lines[0].length > 2 * maxRomSize)
        throw new ParseException("ROM too large");
    p.rom = parseHex(lines[0]);
    p.cycles = parseDecimal(lines[1], 4_000_000_000UL, "cycle count");
    if (count == 3)
        p.events = parseKeySchedule(lines[2], p.cycles);
    return p;
}

///
unittest
{
    auto p = parseProgram("60ff\n12\n3:0001 9:8000\n");
    assert(p.rom == [0x60, 0xff]);
    assert(p.cycles == 12);
    assert(p.events.length == 2);
    assert(p.events[1].cycle == 9 && p.events[1].mask == 0x8000);
}
