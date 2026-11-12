/**
 * The line-oriented query format used by the command-line tool:
 * `<DTSTART> <RRULE> <N>`.
 */
module rrule.query;

import rrule.datetime;
import rrule.expand;
import rrule.rule;

/// One parsed input line.
struct Query
{
    /// Start of the series.
    LocalDateTime dtstart;
    /// The recurrence rule.
    Rule rule;
    /// Maximum number of occurrences to produce.
    size_t limit;
}

/// Parses a line `YYYYMMDDTHHMMSS RRULE N`. Throws `ParseException`.
Query parseQuery(const(char)[] line) @safe pure
{
    const first = indexOfSpace(line, 0);
    const last = lastIndexOfSpace(line);
    if (first < 0 || last <= first)
        throw new ParseException("expected '<DTSTART> <RRULE> <N>': " ~ line.idup);
    Query q;
    q.dtstart = LocalDateTime.parse(line[0 .. first]);
    q.rule = parseRule(line[first + 1 .. last]);
    const n = parseInt(line[last + 1 .. $]);
    if (n < 1)
        throw new ParseException("N must be positive");
    q.limit = n;
    return q;
}

/// Appends the occurrences of `q`, space separated and without a trailing newline, to `sink`.
void formatOccurrences(Sink)(ref const Query q, ref Sink sink)
{
    char[15] buf;
    auto occ = new Occurrences(q.dtstart, cast() q.rule);
    for (size_t i = 0; i < q.limit && !occ.empty; ++i, occ.popFront())
    {
        if (i != 0)
            sink.put(' ');
        occ.front.formatInto(buf[]);
        sink.put(buf[]);
    }
}

private ptrdiff_t indexOfSpace(const(char)[] s, size_t from) @safe pure nothrow @nogc
{
    foreach (i; from .. s.length)
        if (s[i] == ' ')
            return i;
    return -1;
}

private ptrdiff_t lastIndexOfSpace(const(char)[] s) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; s)
        if (c == ' ')
            return i;
    return -1;
}

@safe unittest
{
    const q = parseQuery("19970902T090000 FREQ=DAILY;COUNT=3 100");
    assert(q.limit == 100 && q.rule.count == 3 && q.dtstart.year == 1997);
}

unittest
{
    import std.array : appender;
    import std.exception : assertThrown;

    auto q = parseQuery("20240131T000000 FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000 10");
    auto sink = appender!string;
    formatOccurrences(q, sink);
    assert(sink[] == "20240131T000000 20240229T000000 20240331T000000 20240430T000000");

    q = parseQuery("19970902T090000 FREQ=DAILY 2");
    sink = appender!string;
    formatOccurrences(q, sink);
    assert(sink[] == "19970902T090000 19970903T090000");

    assertThrown!ParseException(parseQuery("19970902T090000 FREQ=DAILY"));
    assertThrown!ParseException(parseQuery("FREQ=DAILY 3"));
    assertThrown!ParseException(parseQuery("19970902T090000 FREQ=DAILY 0"));
}
