/**
 * The recurrence rule record and the parser for RFC 5545 `RRULE` values.
 *
 * Every list-valued `BY…` part is stored as boolean lookup tables indexed by
 * value (separate tables for positive and negative values) so that each
 * filter test during expansion is one or two array reads.
 */
module rrule.rule;


import rrule.calendar : LocalDateTime;
import rrule.errors;
import rrule.timestamp : parseTimestamp;

/// Recurrence frequency.
enum Freq : ubyte
{
    yearly,
    monthly,
    weekly,
    daily,
}

/// A `BYDAY` entry with an ordinal prefix, e.g. `2MO` or `-1FR`.
struct OrdinalDay
{
    /// Signed ordinal (never 0).
    int ordinal;
    /// Weekday, Monday = 0.
    ubyte weekday;
}

/**
 * A parsed recurrence rule.
 *
 * Presence flags (`hasMonth`, …) record which parts were written in the rule;
 * the lookup tables are only meaningful for parts that are present.
 */
struct Rule
{
    /// `FREQ`.
    Freq freq = Freq.yearly;
    /// `INTERVAL` (default 1).
    int interval = 1;
    /// `COUNT` if `hasCount`.
    int count;
    /// True if `COUNT` was given.
    bool hasCount;
    /// `UNTIL` if `hasUntil`.
    LocalDateTime until;
    /// True if `UNTIL` was given.
    bool hasUntil;
    /// `WKST`, Monday = 0 (default Monday).
    int weekStart;

    /// True if `BYMONTH` is present.
    bool hasMonth;
    /// True if `BYMONTHDAY` is present.
    bool hasMonthDay;
    /// True if `BYYEARDAY` is present.
    bool hasYearDay;
    /// True if `BYWEEKNO` is present.
    bool hasWeekNo;
    /// True if `BYDAY` with plain weekday codes is present.
    bool hasWeekdays;

    /// `BYMONTH` table, indexed by month 1–12.
    bool[13] month;
    /// `BYMONTHDAY` positive values, indexed 1–31.
    bool[32] monthDay;
    /// `BYMONTHDAY` negative values, indexed by absolute value 1–31.
    bool[32] monthDayNeg;
    /// `BYYEARDAY` positive values, indexed 1–366.
    bool[367] yearDay;
    /// `BYYEARDAY` negative values, indexed by absolute value 1–366.
    bool[367] yearDayNeg;
    /// `BYWEEKNO` positive values, indexed 1–53.
    bool[54] weekNo;
    /// `BYWEEKNO` negative values, indexed by absolute value 1–53.
    bool[54] weekNoNeg;
    /// Plain `BYDAY` weekdays, indexed 0–6 (Monday = 0).
    bool[7] weekday;
    /// Ordinal `BYDAY` entries (empty unless the list is ordinal-prefixed).
    OrdinalDay[] ordinalDays;
    /// `BYSETPOS` values (empty if absent).
    int[] setPos;

    /// True if any `BYDAY` form is present.
    pure nothrow @nogc @safe bool hasByDay() const
    {
        return hasWeekdays || ordinalDays.length != 0;
    }

    /// Resets the rule to its defaults, keeping array storage for reuse.
    nothrow @trusted void reset()
    {
        auto od = ordinalDays;
        auto sp = setPos;
        this = Rule.init;
        od.length = 0;
        sp.length = 0;
        od.assumeSafeAppend();
        sp.assumeSafeAppend();
        ordinalDays = od;
        setPos = sp;
    }
}

private pure nothrow @safe int weekdayCode(char a, char b)
{
    switch (a)
    {
    case 'M': return b == 'O' ? 0 : -1;
    case 'T': return b == 'U' ? 1 : b == 'H' ? 3 : -1;
    case 'W': return b == 'E' ? 2 : -1;
    case 'F': return b == 'R' ? 4 : -1;
    case 'S': return b == 'A' ? 5 : b == 'U' ? 6 : -1;
    default: return -1;
    }
}

private struct Cursor
{
    const(char)[] text;
    size_t pos;

    @property bool atEnd() const pure nothrow @safe @nogc { return pos >= text.length; }
}

private @safe int parseInteger(ref Cursor c, int lo, int hi, bool allowZero, string what)
{
    bool neg = false;
    if (!c.atEnd && c.text[c.pos] == '-')
    {
        neg = true;
        ++c.pos;
    }
    immutable start = c.pos;
    long v = 0;
    while (!c.atEnd && c.text[c.pos] >= '0' && c.text[c.pos] <= '9')
    {
        v = v * 10 + (c.text[c.pos] - '0');
        if (v > 1_000_000)
            throw new RRuleException("number out of range in " ~ what);
        ++c.pos;
    }
    if (c.pos == start)
        throw new RRuleException("expected a number in " ~ what);
    if (neg)
        v = -v;
    if ((v == 0 && !allowZero) || v < lo || v > hi)
        throw new RRuleException("value out of range in " ~ what);
    return cast(int) v;
}

/// Iterates the `,`-separated items of `value`, calling `item` with a cursor on each.
private void eachItem(const(char)[] value, string what, scope void delegate(ref Cursor) @safe item) @safe
{
    auto c = Cursor(value, 0);
    if (value.length == 0)
        throw new RRuleException("empty value for " ~ what);
    while (true)
    {
        item(c);
        if (c.atEnd)
            break;
        if (c.text[c.pos] != ',')
            throw new RRuleException("unexpected character in " ~ what);
        ++c.pos;
    }
}

/**
 * Parses an `RRULE` value such as `FREQ=MONTHLY;BYDAY=-1FR;COUNT=10` into
 * `rule`, replacing its previous contents. The rule's array storage is reused,
 * so slices of `rule.ordinalDays` / `rule.setPos` obtained earlier are
 * invalidated.
 *
 * Throws: `RRuleException` on malformed or out-of-range input.
 */
@safe void parseRuleInto(ref Rule rule, const(char)[] text)
{
    rule.reset();
    bool haveFreq = false;
    size_t i = 0;
    while (i <= text.length)
    {
        size_t j = i;
        while (j < text.length && text[j] != ';')
            ++j;
        auto part = text[i .. j];
        i = j + 1;
        if (part.length == 0)
            throw new RRuleException("empty rule part");
        size_t eq = 0;
        while (eq < part.length && part[eq] != '=')
            ++eq;
        if (eq == part.length)
            throw new RRuleException("rule part without '=': " ~ part.idup);
        auto name = part[0 .. eq];
        auto value = part[eq + 1 .. $];
        parsePart(rule, name, value, haveFreq);
    }
    if (!haveFreq)
        throw new RRuleException("missing FREQ");
}

private @safe void parsePart(ref Rule rule, const(char)[] name, const(char)[] value, ref bool haveFreq)
{
    switch (name)
    {
    case "FREQ":
        switch (value)
        {
        case "YEARLY": rule.freq = Freq.yearly; break;
        case "MONTHLY": rule.freq = Freq.monthly; break;
        case "WEEKLY": rule.freq = Freq.weekly; break;
        case "DAILY": rule.freq = Freq.daily; break;
        default: throw new RRuleException("unsupported FREQ: " ~ value.idup);
        }
        haveFreq = true;
        break;
    case "INTERVAL":
        auto c = Cursor(value, 0);
        rule.interval = parseInteger(c, 1, 100, false, "INTERVAL");
        break;
    case "COUNT":
        auto c = Cursor(value, 0);
        rule.count = parseInteger(c, 1, 100_000, false, "COUNT");
        rule.hasCount = true;
        break;
    case "UNTIL":
        rule.until = parseTimestamp(value);
        rule.hasUntil = true;
        break;
    case "WKST":
        immutable w = value.length == 2 ? weekdayCode(value[0], value[1]) : -1;
        if (w < 0)
            throw new RRuleException("invalid WKST: " ~ value.idup);
        rule.weekStart = w;
        break;
    case "BYMONTH":
        eachItem(value, "BYMONTH", (ref Cursor c) {
            rule.month[parseInteger(c, 1, 12, false, "BYMONTH")] = true;
        });
        rule.hasMonth = true;
        break;
    case "BYMONTHDAY":
        eachItem(value, "BYMONTHDAY", (ref Cursor c) {
            immutable v = parseInteger(c, -31, 31, false, "BYMONTHDAY");
            if (v > 0) rule.monthDay[v] = true; else rule.monthDayNeg[-v] = true;
        });
        rule.hasMonthDay = true;
        break;
    case "BYYEARDAY":
        eachItem(value, "BYYEARDAY", (ref Cursor c) {
            immutable v = parseInteger(c, -366, 366, false, "BYYEARDAY");
            if (v > 0) rule.yearDay[v] = true; else rule.yearDayNeg[-v] = true;
        });
        rule.hasYearDay = true;
        break;
    case "BYWEEKNO":
        eachItem(value, "BYWEEKNO", (ref Cursor c) {
            immutable v = parseInteger(c, -53, 53, false, "BYWEEKNO");
            if (v > 0) rule.weekNo[v] = true; else rule.weekNoNeg[-v] = true;
        });
        rule.hasWeekNo = true;
        break;
    case "BYDAY":
        eachItem(value, "BYDAY", (ref Cursor c) {
            int ord = 0;
            bool hasOrd = false;
            if (!c.atEnd && (c.text[c.pos] == '-' || (c.text[c.pos] >= '0' && c.text[c.pos] <= '9')))
            {
                ord = parseInteger(c, -53, 53, false, "BYDAY");
                hasOrd = true;
            }
            if (c.pos + 2 > c.text.length)
                throw new RRuleException("invalid BYDAY entry");
            immutable w = weekdayCode(c.text[c.pos], c.text[c.pos + 1]);
            if (w < 0)
                throw new RRuleException("invalid BYDAY weekday");
            c.pos += 2;
            if (hasOrd)
                rule.ordinalDays ~= OrdinalDay(ord, cast(ubyte) w);
            else
            {
                rule.weekday[w] = true;
                rule.hasWeekdays = true;
            }
        });
        break;
    case "BYSETPOS":
        eachItem(value, "BYSETPOS", (ref Cursor c) {
            rule.setPos ~= parseInteger(c, -366, 366, false, "BYSETPOS");
        });
        break;
    default:
        throw new RRuleException("unsupported rule part: " ~ name.idup);
    }
}

/// Parses an `RRULE` value into a fresh `Rule`. See `parseRuleInto`.
@safe Rule parseRule(const(char)[] text)
{
    Rule r;
    parseRuleInto(r, text);
    return r;
}
