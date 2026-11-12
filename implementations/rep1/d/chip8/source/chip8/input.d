/// Parsing of the textual job format (ROM hex, cycle budget, key schedule).
module chip8.input;

import chip8.machine : maxRomSize;

/// A key-state change taking effect immediately before `cycle` executes.
struct KeyEvent
{
    ulong cycle;   /// 0-based cycle number.
    ushort mask;   /// Held keys; bit k set means key k is down.
}

/// A parsed job.
struct Job
{
    ubyte[] rom;          /// ROM bytes.
    ulong cycles;         /// Exact number of cycles to execute.
    KeyEvent[] schedule;  /// Key events in strictly increasing cycle order.
}

/// Thrown on malformed input.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private uint hexValue(char c) @safe pure
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    throw new ParseException("invalid hex digit");
}

/// Decode a hex string (two digits per byte) into bytes.
ubyte[] parseHex(scope const(char)[] s) @safe pure
{
    if (s.length % 2 != 0)
        throw new ParseException("odd number of hex digits");
    auto bytes = new ubyte[s.length / 2];
    foreach (k, ref b; bytes)
        b = cast(ubyte)(hexValue(s[2 * k]) << 4 | hexValue(s[2 * k + 1]));
    return bytes;
}

/// Parse an unsigned decimal integer.
ulong parseDecimal(scope const(char)[] s) @safe pure
{
    if (s.length == 0 || s.length > 19)
        throw new ParseException("invalid decimal number");
    ulong v;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid decimal number");
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Parse a space-separated list of `<cycle>:<mask>` events.
KeyEvent[] parseSchedule(scope const(char)[] s) @safe pure
{
    KeyEvent[] events;
    size_t pos;
    while (pos < s.length)
    {
        size_t end = pos;
        while (end < s.length && s[end] != ' ') ++end;
        auto token = s[pos .. end];
        size_t colon = 0;
        while (colon < token.length && token[colon] != ':') ++colon;
        if (colon == token.length)
            throw new ParseException("key event lacks ':'");
        auto mask = parseHex(token[colon + 1 .. $]);
        if (mask.length != 2)
            throw new ParseException("key mask must be four hex digits");
        events ~= KeyEvent(parseDecimal(token[0 .. colon]), cast(ushort)(mask[0] << 8 | mask[1]));
        pos = end + 1;
    }
    return events;
}

/// Parse a whole job: ROM line, cycles line, optional key-schedule line.
Job parseJob(scope const(char)[] text) @safe pure
{
    string[] lines;
    {
        size_t start;
        foreach (k, c; text)
            if (c == '\n')
            {
                lines ~= text[start .. k].idup;
                start = k + 1;
            }
        if (start < text.length)
            lines ~= text[start .. $].idup;
    }
    foreach (ref l; lines)
        if (l.length && l[$ - 1] == '\r')
            l = l[0 .. $ - 1];

    if (lines.length < 2)
        throw new ParseException("expected a ROM line and a cycles line");

    Job job;
    job.rom = parseHex(lines[0]);
    if (job.rom.length == 0 || job.rom.length > maxRomSize)
        throw new ParseException("ROM must be between 1 and 3584 bytes");
    job.cycles = parseDecimal(lines[1]);
    if (lines.length > 2)
        job.schedule = parseSchedule(lines[2]);
    return job;
}

@safe pure unittest
{
    import std.exception : assertThrown;
    assert(parseHex("00ff10") == [0x00, 0xFF, 0x10]);
    assert(parseDecimal("4000000000") == 4_000_000_000UL);
    assertThrown!ParseException(parseHex("abc"));
    assertThrown!ParseException(parseHex("zz"));
    assertThrown!ParseException(parseDecimal(""));
    assertThrown!ParseException(parseDecimal("12a"));
}

@safe pure unittest
{
    assert(parseSchedule("") == []);
    assert(parseSchedule("9:0300 20:0000") == [KeyEvent(9, 0x0300), KeyEvent(20, 0)]);
}

@safe pure unittest
{
    auto j = parseJob("6001\n12\n3:0001\n");
    assert(j.rom == [0x60, 0x01] && j.cycles == 12 && j.schedule == [KeyEvent(3, 1)]);
    // Trailing newline optional, third line optional or empty.
    assert(parseJob("6001\n0").cycles == 0);
    assert(parseJob("6001\n5\n").schedule.length == 0);
    assert(parseJob("6001\r\n5\r\n").cycles == 5);
}
