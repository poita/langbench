/**
 * Line-oriented batch processing: the engine behind the command-line tool.
 *
 * Each input line is `<DTSTART> <RRULE> <N>`; the output line holds the first
 * `N` occurrences as space-separated `YYYYMMDDTHHMMSS` stamps.
 */
module rrule.batch;

import rrule.calendar;
import rrule.errors;
import rrule.expand;
import rrule.rule;
import rrule.timestamp;

/// A growable byte buffer with an explicit fill level.
struct OutputBuffer
{
    /// Backing storage; `data[0 .. length]` is valid.
    ubyte[] data;
    /// Number of valid bytes.
    size_t length;

    /// Ensures room for `extra` more bytes.
    void reserve(size_t extra)
    {
        if (length + extra > data.length)
        {
            size_t cap = data.length < 4096 ? 4096 : data.length * 2;
            while (cap < length + extra)
                cap *= 2;
            data.length = cap;
        }
    }

    /// Appends one byte.
    void put(ubyte b)
    {
        reserve(1);
        data[length++] = b;
    }

    /// The valid contents.
    const(ubyte)[] contents() const
    {
        return data[0 .. length];
    }

    /// Discards the contents (keeps the storage).
    void clear()
    {
        length = 0;
    }
}

/// Sink that formats occurrences as stamps into an `OutputBuffer`.
struct StampSink
{
    /// Destination buffer.
    OutputBuffer* output;
    /// Pre-formatted `HHMMSS` of DTSTART.
    ubyte[6] timePart;
    /// True until the first occurrence of the current line has been written.
    bool first = true;

    /// Writes one occurrence.
    void put(int dayNum)
    {
        output.reserve(stampLength + 1);
        auto buf = output.data;
        size_t at = output.length;
        if (!first)
            buf[at++] = ' ';
        first = false;
        putStamp(buf[at .. at + stampLength], civilFromDayNumber(dayNum), timePart[]);
        output.length = at + stampLength;
    }
}

private int parseCount(const(char)[] s)
{
    if (s.length == 0 || s.length > 6)
        throw new RRuleException("invalid limit: " ~ s.idup);
    int v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new RRuleException("invalid limit: " ~ s.idup);
        v = v * 10 + (c - '0');
    }
    return v;
}

/**
 * Processes all lines of `input`, appending one output line per input line to
 * `output`. Whenever the buffer exceeds `flushThreshold` bytes, `flush` is
 * called with its contents and the buffer is cleared; a final flush happens at
 * the end. Empty lines are ignored.
 *
 * Throws: `RRuleException` naming the offending line; output produced for the
 * preceding lines has already been flushed or remains in `output`.
 */
void processInput(const(char)[] input, ref OutputBuffer output,
    scope void delegate(const(ubyte)[]) flush, size_t flushThreshold = 1 << 22)
{
    Expander expander;
    Rule rule;
    size_t pos = 0;
    size_t lineNo = 0;
    while (pos < input.length)
    {
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            ++end;
        auto line = input[pos .. end];
        pos = end + 1;
        ++lineNo;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (line.length == 0)
            continue;
        try
            processLine(line, expander, rule, output);
        catch (RRuleException e)
        {
            throw new RRuleException("line " ~ lineNoString(lineNo) ~ ": " ~ e.msg);
        }
        if (output.length >= flushThreshold)
        {
            flush(output.contents);
            output.clear();
        }
    }
    if (output.length)
    {
        flush(output.contents);
        output.clear();
    }
}

private string lineNoString(size_t n)
{
    char[20] tmp;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    return tmp[i .. $].idup;
}

/// Processes one `<DTSTART> <RRULE> <N>` line, appending its output line.
void processLine(const(char)[] line, ref Expander expander, ref Rule rule, ref OutputBuffer output)
{
    size_t firstSpace = 0;
    while (firstSpace < line.length && line[firstSpace] != ' ')
        ++firstSpace;
    size_t lastSpace = line.length;
    while (lastSpace > 0 && line[lastSpace - 1] != ' ')
        --lastSpace;
    if (firstSpace >= line.length || lastSpace == 0 || lastSpace - 1 <= firstSpace)
        throw new RRuleException("expected '<DTSTART> <RRULE> <N>'");
    immutable start = parseTimestamp(line[0 .. firstSpace]);
    parseRuleInto(rule, line[firstSpace + 1 .. lastSpace - 1]);
    immutable limit = parseCount(line[lastSpace .. $]);

    StampSink sink;
    sink.output = &output;
    putTimeOfDay(sink.timePart[], start.secondsOfDay);
    expander.expand(rule, start, limit, sink);
    output.put('\n');
}
