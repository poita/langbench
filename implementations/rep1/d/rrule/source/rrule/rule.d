/**
 * Recurrence rule representation and parsing of the `RRULE` value syntax.
 */
module rrule.rule;

import rrule.calendar : Weekday;
import rrule.datetime;

/// Recurrence frequency.
enum Freq
{
    yearly,
    monthly,
    weekly,
    daily,
}

/// One `BYDAY` entry: a weekday with an optional ordinal (`2MO`, `-1FR`).
struct ByDay
{
    /// Weekday, 0 = Monday … 6 = Sunday.
    int weekday;
    /// Signed ordinal; 0 when the entry has none.
    int ordinal;
}

/// A parsed recurrence rule. Defaults that depend on DTSTART are *not* applied here.
struct Rule
{
    /// `FREQ`.
    Freq freq;
    /// `INTERVAL` (default 1).
    int interval = 1;
    /// `COUNT`, or 0 when absent.
    int count;
    /// Whether `UNTIL` is present.
    bool hasUntil;
    /// `UNTIL`; meaningful only if `hasUntil`.
    LocalDateTime until;
    /// `WKST` (default Monday).
    int weekStart = Weekday.monday;
    /// `BYMONTH`.
    int[] byMonth;
    /// `BYMONTHDAY`.
    int[] byMonthDay;
    /// `BYYEARDAY`.
    int[] byYearDay;
    /// `BYWEEKNO`.
    int[] byWeekNo;
    /// `BYDAY`.
    ByDay[] byDay;
    /// `BYSETPOS`.
    int[] bySetPos;
}

/**
 * Parses an `RRULE` value such as `FREQ=MONTHLY;BYDAY=-1FR;COUNT=10`.
 *
 * Throws: `ParseException` on malformed input. Only the syntax is checked,
 * not the cross-part restrictions of RFC 5545.
 */
Rule parseRule(const(char)[] text) @safe pure
{
    Rule r;
    bool haveFreq;
    foreach (part; splitOn(text, ';'))
    {
        const eq = indexOf(part, '=');
        if (eq < 0)
            throw new ParseException("expected NAME=VALUE: " ~ part.idup);
        const name = part[0 .. eq];
        const value = part[eq + 1 .. $];
        switch (name)
        {
        case "FREQ":
            switch (value)
            {
            case "YEARLY":
                r.freq = Freq.yearly;
                break;
            case "MONTHLY":
                r.freq = Freq.monthly;
                break;
            case "WEEKLY":
                r.freq = Freq.weekly;
                break;
            case "DAILY":
                r.freq = Freq.daily;
                break;
            default:
                throw new ParseException("unsupported FREQ: " ~ value.idup);
            }
            haveFreq = true;
            break;
        case "INTERVAL":
            r.interval = parseInt(value);
            if (r.interval < 1)
                throw new ParseException("INTERVAL must be positive");
            break;
        case "COUNT":
            r.count = parseInt(value);
            if (r.count < 1)
                throw new ParseException("COUNT must be positive");
            break;
        case "UNTIL":
            r.until = LocalDateTime.parse(value);
            r.hasUntil = true;
            break;
        case "WKST":
            r.weekStart = parseWeekday(value);
            break;
        case "BYMONTH":
            r.byMonth = parseIntList(value);
            break;
        case "BYMONTHDAY":
            r.byMonthDay = parseIntList(value);
            break;
        case "BYYEARDAY":
            r.byYearDay = parseIntList(value);
            break;
        case "BYWEEKNO":
            r.byWeekNo = parseIntList(value);
            break;
        case "BYSETPOS":
            r.bySetPos = parseIntList(value);
            break;
        case "BYDAY":
            r.byDay = null;
            foreach (item; splitOn(value, ','))
            {
                if (item.length < 2)
                    throw new ParseException("invalid BYDAY entry: " ~ item.idup);
                ByDay b;
                b.weekday = parseWeekday(item[$ - 2 .. $]);
                const prefix = item[0 .. $ - 2];
                b.ordinal = prefix.length ? parseInt(prefix) : 0;
                r.byDay ~= b;
            }
            break;
        default:
            throw new ParseException("unsupported rule part: " ~ name.idup);
        }
    }
    if (!haveFreq)
        throw new ParseException("FREQ is required");
    validate(r);
    return r;
}

private void validate(const ref Rule r) @safe pure
{
    void range(const int[] values, int limit, string what)
    {
        foreach (v; values)
            if (v == 0 || v < -limit || v > limit)
                throw new ParseException("value out of range in " ~ what);
    }

    foreach (m; r.byMonth)
        if (m < 1 || m > 12)
            throw new ParseException("value out of range in BYMONTH");
    range(r.byMonthDay, 31, "BYMONTHDAY");
    range(r.byYearDay, 366, "BYYEARDAY");
    range(r.byWeekNo, 53, "BYWEEKNO");
    range(r.bySetPos, 366, "BYSETPOS");
    foreach (b; r.byDay)
        if (b.ordinal < -53 || b.ordinal > 53)
            throw new ParseException("ordinal out of range in BYDAY");
}

private int parseWeekday(const(char)[] s) @safe pure
{
    switch (s)
    {
    case "MO":
        return Weekday.monday;
    case "TU":
        return Weekday.tuesday;
    case "WE":
        return Weekday.wednesday;
    case "TH":
        return Weekday.thursday;
    case "FR":
        return Weekday.friday;
    case "SA":
        return Weekday.saturday;
    case "SU":
        return Weekday.sunday;
    default:
        throw new ParseException("invalid weekday: " ~ s.idup);
    }
}

/// Parses a decimal integer with an optional leading `-`.
int parseInt(const(char)[] s) @safe pure
{
    bool neg;
    auto t = s;
    if (t.length && t[0] == '-')
    {
        neg = true;
        t = t[1 .. $];
    }
    if (t.length == 0 || t.length > 9)
        throw new ParseException("invalid integer: " ~ s.idup);
    int v;
    foreach (c; t)
    {
        if (c < '0' || c > '9')
            throw new ParseException("invalid integer: " ~ s.idup);
        v = v * 10 + (c - '0');
    }
    return neg ? -v : v;
}

private int[] parseIntList(const(char)[] s) @safe pure
{
    int[] r;
    foreach (item; splitOn(s, ','))
        r ~= parseInt(item);
    return r;
}

private ptrdiff_t indexOf(const(char)[] s, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

private const(char)[][] splitOn(const(char)[] s, char sep) @safe pure nothrow
{
    const(char)[][] r;
    size_t start;
    foreach (i, ch; s)
        if (ch == sep)
        {
            r ~= s[start .. i];
            start = i + 1;
        }
    r ~= s[start .. $];
    return r;
}

///
@safe unittest
{
    const r = parseRule("FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR,MO;WKST=SU;COUNT=10");
    assert(r.freq == Freq.monthly && r.interval == 2 && r.count == 10);
    assert(r.weekStart == Weekday.sunday);
    assert(r.byDay == [ByDay(Weekday.friday, -1), ByDay(Weekday.monday, 0)]);
}

@safe unittest
{
    import std.exception : assertThrown;

    const r = parseRule("FREQ=YEARLY;UNTIL=20240430T000000;BYMONTH=1,12;BYMONTHDAY=-1,31;"
            ~ "BYYEARDAY=-366,366;BYWEEKNO=53,-53;BYSETPOS=-1,1");
    assert(r.hasUntil && r.until == LocalDateTime(2024, 4, 30));
    assert(r.byMonth == [1, 12] && r.byMonthDay == [-1, 31]);
    assert(r.byYearDay == [-366, 366] && r.byWeekNo == [53, -53] && r.bySetPos == [-1, 1]);
    assert(r.interval == 1 && r.count == 0 && r.weekStart == Weekday.monday);

    assertThrown!ParseException(parseRule("INTERVAL=2"));
    assertThrown!ParseException(parseRule("FREQ=HOURLY"));
    assertThrown!ParseException(parseRule("FREQ=DAILY;BYDAY=XX"));
    assertThrown!ParseException(parseRule("FREQ=DAILY;COUNT=x"));
    assertThrown!ParseException(parseRule("FREQ=DAILY;BYMONTH=13"));
    assertThrown!ParseException(parseRule("FREQ=DAILY;BYMONTHDAY=0"));
    assertThrown!ParseException(parseRule("FREQ=DAILY;FOO=1"));
    assertThrown!ParseException(parseRule("FREQ"));
}
