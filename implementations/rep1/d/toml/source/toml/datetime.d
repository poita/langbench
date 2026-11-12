/**
 * Validation and canonicalisation of TOML date and time literals.
 *
 * Date-times are handled purely as text: fields are range-checked and the
 * separator, fractional seconds and zero offsets are normalised, but no
 * calendar arithmetic or time zone conversion is ever performed.
 */
module toml.datetime;

import toml.value : Kind;

private bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }

private bool digits(const(char)[] s, size_t from, size_t count) @safe pure nothrow @nogc
{
    if (from + count > s.length)
        return false;
    foreach (c; s[from .. from + count])
        if (!isDigit(c))
            return false;
    return true;
}

private uint num(const(char)[] s, size_t from, size_t count) @safe pure nothrow @nogc
{
    uint v = 0;
    foreach (c; s[from .. from + count])
        v = v * 10 + (c - '0');
    return v;
}

private bool isLeap(uint y) @safe pure nothrow @nogc
{
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

private bool validDate(const(char)[] s) @safe pure nothrow @nogc
{
    // YYYY-MM-DD
    if (s.length != 10 || !digits(s, 0, 4) || s[4] != '-' || !digits(s, 5, 2)
        || s[7] != '-' || !digits(s, 8, 2))
        return false;
    immutable year = num(s, 0, 4);
    immutable month = num(s, 5, 2);
    immutable day = num(s, 8, 2);
    if (year < 1 || month < 1 || month > 12 || day < 1)
        return false;
    static immutable uint[12] dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    immutable maxDay = (month == 2 && isLeap(year)) ? 29 : dim[month - 1];
    return day <= maxDay;
}

/**
 * Validates a time `HH:MM:SS[.frac][offset]` and appends its canonical form to `out_`.
 * `allowOffset` selects whether an offset is expected (true) or forbidden (false).
 * `sawOffset` reports whether one was present.
 */
private bool canonicalTime(const(char)[] s, bool allowOffset, ref char[] out_, out bool sawOffset)
    @safe pure
{
    sawOffset = false;
    if (s.length < 8 || !digits(s, 0, 2) || s[2] != ':' || !digits(s, 3, 2)
        || s[5] != ':' || !digits(s, 6, 2))
        return false;
    if (num(s, 0, 2) > 23 || num(s, 3, 2) > 59 || num(s, 6, 2) > 59)
        return false;
    out_ ~= s[0 .. 8];
    size_t i = 8;
    if (i < s.length && s[i] == '.')
    {
        immutable fracStart = ++i;
        while (i < s.length && isDigit(s[i]))
            ++i;
        if (i == fracStart)
            return false;
        size_t fracEnd = i;
        while (fracEnd > fracStart && s[fracEnd - 1] == '0')
            --fracEnd;
        if (fracEnd > fracStart)
        {
            out_ ~= '.';
            out_ ~= s[fracStart .. fracEnd];
        }
    }
    if (i == s.length)
        return true;
    if (!allowOffset)
        return false;
    sawOffset = true;
    if ((s[i] == 'Z' || s[i] == 'z') && i + 1 == s.length)
    {
        out_ ~= 'Z';
        return true;
    }
    if ((s[i] == '+' || s[i] == '-') && s.length == i + 6 && digits(s, i + 1, 2)
        && s[i + 3] == ':' && digits(s, i + 4, 2))
    {
        if (num(s, i + 1, 2) > 23 || num(s, i + 4, 2) > 59)
            return false;
        if (s[i + 1 .. $] == "00:00")
            out_ ~= 'Z';
        else
            out_ ~= s[i .. $];
        return true;
    }
    return false;
}

/**
 * Parses a date, time or date-time literal.
 *
 * `s` is the literal as written (the date and time may be separated by `T`, `t`
 * or a single space). On success returns true and sets `kind` and the canonical
 * `text`; otherwise returns false.
 */
bool parseDateTime(const(char)[] s, out Kind kind, out string text) @safe pure
{
    char[] buf;
    buf.reserve(40);
    if (s.length >= 5 && s[4] == '-')
    {
        if (s.length < 10 || !validDate(s[0 .. 10]))
            return false;
        buf ~= s[0 .. 10];
        if (s.length == 10)
        {
            kind = Kind.localDate;
            text = s.idup;
            return true;
        }
        if (s[10] != 'T' && s[10] != 't' && s[10] != ' ')
            return false;
        buf ~= 'T';
        bool offset;
        if (!canonicalTime(s[11 .. $], true, buf, offset))
            return false;
        kind = offset ? Kind.offsetDateTime : Kind.localDateTime;
        text = buf.idup;
        return true;
    }
    if (s.length >= 3 && s[2] == ':')
    {
        bool offset;
        if (!canonicalTime(s, false, buf, offset))
            return false;
        kind = Kind.localTime;
        text = buf.idup;
        return true;
    }
    return false;
}

unittest
{
    Kind k;
    string t;
    void ok(string s, Kind ek, string et)
    {
        assert(parseDateTime(s, k, t), s);
        assert(k == ek && t == et, s ~ " -> " ~ t);
    }
    void bad(string s) { assert(!parseDateTime(s, k, t), s); }

    ok("1979-05-27", Kind.localDate, "1979-05-27");
    ok("07:32:00", Kind.localTime, "07:32:00");
    ok("00:32:00.999999", Kind.localTime, "00:32:00.999999");
    ok("1979-05-27T07:32:00", Kind.localDateTime, "1979-05-27T07:32:00");
    ok("1979-05-27 07:32:00.500", Kind.localDateTime, "1979-05-27T07:32:00.5");
    ok("1979-05-27t07:32:00.000", Kind.localDateTime, "1979-05-27T07:32:00");
    ok("1987-07-05 17:45:00z", Kind.offsetDateTime, "1987-07-05T17:45:00Z");
    ok("1987-07-05T17:45:56.600+08:00", Kind.offsetDateTime, "1987-07-05T17:45:56.6+08:00");
    ok("1979-05-27t07:32:00-00:00", Kind.offsetDateTime, "1979-05-27T07:32:00Z");
    ok("1979-05-27T07:32:00+00:00", Kind.offsetDateTime, "1979-05-27T07:32:00Z");
    ok("2024-02-29", Kind.localDate, "2024-02-29");
    ok("1979-05-27T07:32:00-08:00", Kind.offsetDateTime, "1979-05-27T07:32:00-08:00");

    foreach (b; ["1987-7-05", "2023-02-29", "1900-02-29", "2024-13-01", "2024-00-10", "2024-04-31",
                 "0000-01-01", "07:32", "24:00:00", "12:60:00", "12:00:60", "07:32:00Z",
                 "1979-05-27T07:32:00+24:00", "1979-05-27T07:32:00+08:60", "1979-05-27T07:32:00+0800",
                 "1979-05-27T07:32:00.", "1979-05-27T", "1979-05-27X07:32:00", "1979-05-27T07:32:00 ",
                 "١٩٧٩-05-27"])
        bad(b);
}
