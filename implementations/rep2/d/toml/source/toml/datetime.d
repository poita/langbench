/**
 * Textual validation and canonicalisation of TOML date/time values.
 *
 * No calendar library is involved: fields are checked arithmetically and the
 * canonical text is built from the original characters.
 */
module toml.datetime;

import toml.node : ScalarType;

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Parses `n` ASCII digits at `s[i..]` into `v`, advancing `i`.
private bool digits(const(char)[] s, ref size_t i, size_t n, out uint v) @safe pure nothrow @nogc
{
    if (i + n > s.length)
        return false;
    v = 0;
    foreach (k; 0 .. n)
    {
        immutable c = s[i + k];
        if (!isDigit(c))
            return false;
        v = v * 10 + (c - '0');
    }
    i += n;
    return true;
}

/// True when `year` is a Gregorian leap year.
bool isLeapYear(uint year) @safe pure nothrow @nogc
{
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

/// Number of days in `month` (1-12) of `year`.
uint daysInMonth(uint year, uint month) @safe pure nothrow @nogc
{
    static immutable uint[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return (month == 2 && isLeapYear(year)) ? 29 : days[month - 1];
}

/// Validates `YYYY-MM-DD` at `s[0..10]`.
private bool validDate(const(char)[] s) @safe pure nothrow @nogc
{
    size_t i = 0;
    uint y, m, d;
    if (!digits(s, i, 4, y) || s[i++] != '-')
        return false;
    if (!digits(s, i, 2, m) || s[i++] != '-')
        return false;
    if (!digits(s, i, 2, d))
        return false;
    return y >= 1 && m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m);
}

/// Validates `HH:MM:SS[.frac]` starting at `s[i]`; advances `i` past it and
/// appends the canonical text to `canon`.
private bool scanTime(const(char)[] s, ref size_t i, ref char[] canon) @safe pure nothrow
{
    immutable start = i;
    uint h, m, sec;
    if (!digits(s, i, 2, h) || i >= s.length || s[i++] != ':')
        return false;
    if (!digits(s, i, 2, m) || i >= s.length || s[i++] != ':')
        return false;
    if (!digits(s, i, 2, sec))
        return false;
    if (h > 23 || m > 59 || sec > 59)
        return false;
    canon ~= s[start .. i];
    if (i < s.length && s[i] == '.')
    {
        size_t j = i + 1;
        while (j < s.length && isDigit(s[j]))
            j++;
        if (j == i + 1)
            return false; // '.' needs at least one digit
        size_t end = j;
        while (end > i + 1 && s[end - 1] == '0')
            end--;
        if (end > i + 1)
            canon ~= s[i .. end];
        i = j;
    }
    return true;
}

/**
 * Validates a TOML date/time token and produces its canonical text.
 *
 * `s` is the token as written, e.g. `1979-05-27t07:32:00.500-00:00`.
 * On success returns true, sets `type` and `canon`.
 */
bool parseDateTime(const(char)[] s, out ScalarType type, out string canon) @safe pure nothrow
{
    char[] buf;
    size_t i = 0;
    if (s.length >= 3 && s[2] == ':')
    {
        if (!scanTime(s, i, buf) || i != s.length)
            return false;
        type = ScalarType.timeLocal;
        canon = buf.idup;
        return true;
    }
    if (s.length < 10 || !validDate(s[0 .. 10]))
        return false;
    buf ~= s[0 .. 10];
    if (s.length == 10)
    {
        type = ScalarType.dateLocal;
        canon = buf.idup;
        return true;
    }
    immutable sep = s[10];
    if (sep != 'T' && sep != 't' && sep != ' ')
        return false;
    buf ~= 'T';
    i = 11;
    if (!scanTime(s, i, buf))
        return false;
    if (i == s.length)
    {
        type = ScalarType.datetimeLocal;
        canon = buf.idup;
        return true;
    }
    if (s[i] == 'Z' || s[i] == 'z')
    {
        if (i + 1 != s.length)
            return false;
        buf ~= 'Z';
    }
    else if (s[i] == '+' || s[i] == '-')
    {
        size_t j = i + 1;
        uint oh, om;
        if (!digits(s, j, 2, oh) || j >= s.length || s[j++] != ':' || !digits(s, j, 2, om)
            || j != s.length)
            return false;
        if (oh > 23 || om > 59)
            return false;
        if (oh == 0 && om == 0) // +00:00 and -00:00 are both UTC
            buf ~= 'Z';
        else
            buf ~= s[i .. $];
    }
    else
        return false;
    type = ScalarType.datetime;
    canon = buf.idup;
    return true;
}

unittest
{
    ScalarType t;
    string c;
    assert(parseDateTime("1987-07-05 17:45:00z", t, c) && t == ScalarType.datetime
        && c == "1987-07-05T17:45:00Z");
    assert(parseDateTime("1987-07-05T17:45:56.600+08:00", t, c) && c == "1987-07-05T17:45:56.6+08:00");
    assert(parseDateTime("1979-05-27t07:32:00-00:00", t, c) && c == "1979-05-27T07:32:00Z");
    assert(parseDateTime("1979-05-27T07:32:00.000", t, c) && t == ScalarType.datetimeLocal
        && c == "1979-05-27T07:32:00");
    assert(parseDateTime("1979-05-27", t, c) && t == ScalarType.dateLocal && c == "1979-05-27");
    assert(parseDateTime("07:32:00.0010", t, c) && t == ScalarType.timeLocal && c == "07:32:00.001");
    assert(parseDateTime("2000-02-29", t, c));
    assert(!parseDateTime("1900-02-29", t, c));
    assert(!parseDateTime("2023-02-29", t, c));
    assert(!parseDateTime("0000-01-01", t, c));
    assert(!parseDateTime("1987-7-05", t, c));
    assert(!parseDateTime("17:45", t, c));
    assert(!parseDateTime("17:45:60", t, c));
    assert(!parseDateTime("24:00:00", t, c));
    assert(!parseDateTime("1979-05-27T07:32:00+24:00", t, c));
    assert(!parseDateTime("1979-05-27T07:32:00.", t, c));
    assert(!parseDateTime("07:32:00Z", t, c));
    assert(!parseDateTime("1979-05-27T", t, c));
    assert(!parseDateTime("1979-05-27x07:32:00", t, c));
    assert(!parseDateTime("1979-05-27T٠٧:32:00", t, c));
}
