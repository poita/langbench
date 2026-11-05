/**
 * Parsing and formatting of the `YYYYMMDDTHHMMSS` date-time notation.
 */
module rrule.timestamp;

import rrule.calendar;
import rrule.errors;

/// Length in characters of a `YYYYMMDDTHHMMSS` stamp.
enum stampLength = 15;

private pure nothrow @nogc @safe int digits(const(char)[] s, size_t from, size_t count, ref bool ok)
{
    int v = 0;
    foreach (i; from .. from + count)
    {
        immutable c = s[i];
        if (c < '0' || c > '9')
        {
            ok = false;
            return 0;
        }
        v = v * 10 + (c - '0');
    }
    return v;
}

/**
 * Parses `YYYYMMDDTHHMMSS`.
 *
 * Throws: `RRuleException` if the text is not exactly a valid date-time.
 */
@safe LocalDateTime parseTimestamp(const(char)[] text)
{
    if (text.length != stampLength || text[8] != 'T')
        throw new RRuleException("invalid date-time: " ~ text.idup);
    bool ok = true;
    immutable y = digits(text, 0, 4, ok);
    immutable mo = digits(text, 4, 2, ok);
    immutable d = digits(text, 6, 2, ok);
    immutable h = digits(text, 9, 2, ok);
    immutable mi = digits(text, 11, 2, ok);
    immutable s = digits(text, 13, 2, ok);
    if (!ok || !isValidDate(y, mo, d) || h > 23 || mi > 59 || s > 59)
        throw new RRuleException("invalid date-time: " ~ text.idup);
    return LocalDateTime(CivilDate(y, mo, d), h, mi, s);
}

/// Writes two decimal digits of `v` (0–99) at `dst[0 .. 2]`.
pure nothrow @nogc @safe void put2(ubyte[] dst, int v)
{
    dst[0] = cast(ubyte)('0' + v / 10);
    dst[1] = cast(ubyte)('0' + v % 10);
}

/// Writes the `HHMMSS` part of a time of day (`secs` seconds after midnight).
pure nothrow @nogc @safe void putTimeOfDay(ubyte[] dst, int secs)
{
    put2(dst[0 .. 2], secs / 3600);
    put2(dst[2 .. 4], secs / 60 % 60);
    put2(dst[4 .. 6], secs % 60);
}

/**
 * Writes the 15-byte stamp `YYYYMMDDTHHMMSS` for `date` into `dst[0 .. 15]`.
 * `timePart` is the pre-formatted six-byte `HHMMSS` of the time of day.
 */
pure nothrow @nogc @safe void putStamp(ubyte[] dst, CivilDate date, const(ubyte)[] timePart)
{
    put2(dst[0 .. 2], date.year / 100);
    put2(dst[2 .. 4], date.year % 100);
    put2(dst[4 .. 6], date.month);
    put2(dst[6 .. 8], date.day);
    dst[8] = 'T';
    dst[9 .. 15] = timePart[0 .. 6];
}

/// Formats a date-time as a `YYYYMMDDTHHMMSS` string.
@safe string formatTimestamp(LocalDateTime dt)
{
    auto buf = new ubyte[stampLength];
    ubyte[6] t;
    putTimeOfDay(t[], dt.secondsOfDay);
    putStamp(buf, dt.date, t[]);
    return (() @trusted => cast(string) buf.idup)();
}
