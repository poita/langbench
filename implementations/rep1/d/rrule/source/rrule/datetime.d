/**
 * A floating (time-zone-less) date-time and its `YYYYMMDDTHHMMSS` text form.
 */
module rrule.datetime;

import rrule.calendar;

/// Thrown when text cannot be parsed.
class ParseException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A calendar date with a time of day, without a time zone.
struct LocalDateTime
{
    /// Year (1000–9999 in valid input).
    int year = 1;
    /// Month, 1–12.
    int month = 1;
    /// Day of month.
    int day = 1;
    /// Hour, 0–23.
    int hour;
    /// Minute, 0–59.
    int minute;
    /// Second, 0–59.
    int second;

    /// Day number (days since 1 January 0001) of the date part.
    long dayNumber() const @safe pure nothrow @nogc
    {
        return daysFromCivil(year, month, day);
    }

    /// Seconds since midnight.
    int secondOfDay() const @safe pure nothrow @nogc
    {
        return hour * 3600 + minute * 60 + second;
    }

    /// Builds a value from a day number and a number of seconds since midnight.
    static LocalDateTime fromDayAndSecond(long dayNumber, int secondOfDay) @safe pure nothrow @nogc
    {
        const c = civilFromDays(dayNumber);
        return LocalDateTime(cast(int) c.year, c.month, c.day,
            secondOfDay / 3600, secondOfDay / 60 % 60, secondOfDay % 60);
    }

    /// Parses `YYYYMMDDTHHMMSS`; the date must exist.
    static LocalDateTime parse(const(char)[] text) @safe pure
    {
        if (text.length != 15 || text[8] != 'T')
            throw new ParseException("invalid date-time: " ~ text.idup);
        LocalDateTime r;
        r.year = digits(text[0 .. 4]);
        r.month = digits(text[4 .. 6]);
        r.day = digits(text[6 .. 8]);
        r.hour = digits(text[9 .. 11]);
        r.minute = digits(text[11 .. 13]);
        r.second = digits(text[13 .. 15]);
        if (r.month < 1 || r.month > 12 || r.day < 1 || r.day > daysInMonth(r.year, r.month)
            || r.hour > 23 || r.minute > 59 || r.second > 59)
            throw new ParseException("invalid date-time: " ~ text.idup);
        return r;
    }

    /// Writes `YYYYMMDDTHHMMSS` into the first 15 characters of `buf`.
    void formatInto(char[] buf) const @safe pure nothrow @nogc
    in (buf.length >= 15)
    {
        put(buf[0 .. 4], year);
        put(buf[4 .. 6], month);
        put(buf[6 .. 8], day);
        buf[8] = 'T';
        put(buf[9 .. 11], hour);
        put(buf[11 .. 13], minute);
        put(buf[13 .. 15], second);
    }

    /// The `YYYYMMDDTHHMMSS` text form.
    string toString() const @safe pure nothrow
    {
        auto buf = new char[15];
        formatInto(buf);
        return (() @trusted => cast(string) buf)();
    }

    /// Chronological comparison.
    int opCmp(const LocalDateTime o) const @safe pure nothrow @nogc
    {
        const a = dayNumber() * 86_400 + secondOfDay();
        const b = o.dayNumber() * 86_400 + o.secondOfDay();
        return a < b ? -1 : (a > b ? 1 : 0);
    }
}

private int digits(const(char)[] s) @safe pure
{
    int v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid digit in date-time");
        v = v * 10 + (c - '0');
    }
    return v;
}

private void put(char[] dst, long value) @safe pure nothrow @nogc
{
    foreach_reverse (ref c; dst)
    {
        c = cast(char)('0' + value % 10);
        value /= 10;
    }
}

///
@safe unittest
{
    auto t = LocalDateTime.parse("19970902T090000");
    assert(t.year == 1997 && t.month == 9 && t.day == 2 && t.hour == 9);
    assert(t.toString == "19970902T090000");
    assert(LocalDateTime.fromDayAndSecond(t.dayNumber, t.secondOfDay) == t);
}

@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(LocalDateTime.parse("20230229T000000"));
    assertThrown!ParseException(LocalDateTime.parse("20230228T240000"));
    assertThrown!ParseException(LocalDateTime.parse("2023022800000"));
    assertThrown!ParseException(LocalDateTime.parse("20230228X000000"));
    assertThrown!ParseException(LocalDateTime.parse("2023O228T000000"));
    assert(LocalDateTime.parse("10000101T000000") < LocalDateTime.parse("10000101T000001"));
    assert(LocalDateTime.parse("99991231T235959").toString == "99991231T235959");
}
