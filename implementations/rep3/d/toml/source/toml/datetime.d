/// Textual validation and canonicalisation of TOML date-times.
///
/// No calendar arithmetic or time-zone conversion is performed: fields are
/// range-checked and the canonical text is produced directly.
module toml.datetime;

import toml.node : Kind;

private bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }

private bool twoDigits(const(char)[] t, size_t i, out uint v) pure nothrow @safe @nogc
{
    if (i + 2 > t.length || !isDigit(t[i]) || !isDigit(t[i + 1])) return false;
    v = (t[i] - '0') * 10 + (t[i + 1] - '0');
    return true;
}

private bool isLeap(uint y) pure nothrow @safe @nogc { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

/// True when `t` starts with the shape `DDDD-` (a date).
bool looksLikeDate(const(char)[] t) pure nothrow @safe @nogc
{
    return t.length >= 5 && isDigit(t[0]) && isDigit(t[1]) && isDigit(t[2]) && isDigit(t[3]) && t[4] == '-';
}

/// True when `t` starts with the shape `DD:` (a time).
bool looksLikeTime(const(char)[] t) pure nothrow @safe @nogc
{
    return t.length >= 3 && isDigit(t[0]) && isDigit(t[1]) && t[2] == ':';
}

private bool checkDate(const(char)[] t) pure nothrow @safe @nogc
{
    if (t.length < 10 || t[4] != '-' || t[7] != '-') return false;
    foreach (i; [0, 1, 2, 3])
        if (!isDigit(t[i])) return false;
    uint year = (t[0] - '0') * 1000 + (t[1] - '0') * 100 + (t[2] - '0') * 10 + (t[3] - '0');
    uint mon, day;
    if (!twoDigits(t, 5, mon) || !twoDigits(t, 8, day)) return false;
    if (year < 1 || mon < 1 || mon > 12 || day < 1) return false;
    static immutable uint[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    uint dim = days[mon - 1];
    if (mon == 2 && isLeap(year)) dim = 29;
    return day <= dim;
}

/// Validates `HH:MM:SS[.frac]` at `t[from..]`; `end` is set to the index after it.
private bool checkTime(const(char)[] t, size_t from, out size_t end) pure nothrow @safe @nogc
{
    uint h, m, s;
    if (!twoDigits(t, from, h) || from + 2 >= t.length || t[from + 2] != ':') return false;
    if (!twoDigits(t, from + 3, m) || from + 5 >= t.length || t[from + 5] != ':') return false;
    if (!twoDigits(t, from + 6, s)) return false;
    if (h > 23 || m > 59 || s > 59) return false;
    size_t i = from + 8;
    if (i < t.length && t[i] == '.')
    {
        i++;
        immutable st = i;
        while (i < t.length && isDigit(t[i])) i++;
        if (i == st) return false;
    }
    end = i;
    return true;
}

/// Appends a time (`HH:MM:SS[.frac]`) in canonical form, trimming trailing zeros of the fraction.
private void appendTime(ref char[] o, const(char)[] t) pure nothrow @safe
{
    o ~= t[0 .. 8];
    if (t.length > 8)
    {
        size_t e = t.length;
        while (e > 9 && t[e - 1] == '0') e--;
        if (e > 9) o ~= t[8 .. e];
    }
}

/**
 * Validates a date/time token and produces its canonical text.
 *
 * Params:
 *   t = token as written (date, time, or date-time with `T`, `t` or a space)
 *   kind = the resulting kind
 *   text = the canonical text
 * Returns: false if `t` is not a valid date-time of any of the four kinds.
 */
bool parseDateTime(const(char)[] t, out Kind kind, out string text) pure nothrow @safe
{
    char[] o;
    if (looksLikeDate(t))
    {
        if (!checkDate(t)) return false;
        if (t.length == 10)
        {
            kind = Kind.localDate;
            text = t.idup;
            return true;
        }
        if (t[10] != 'T' && t[10] != 't' && t[10] != ' ') return false;
        size_t end;
        if (!checkTime(t, 11, end)) return false;
        o ~= t[0 .. 10];
        o ~= 'T';
        appendTime(o, t[11 .. end]);
        if (end == t.length)
        {
            kind = Kind.localDateTime;
            text = o.idup;
            return true;
        }
        const rest = t[end .. $];
        if (rest == "Z" || rest == "z")
            o ~= 'Z';
        else
        {
            if (rest.length != 6 || (rest[0] != '+' && rest[0] != '-') || rest[3] != ':') return false;
            uint oh, om;
            if (!twoDigits(rest, 1, oh) || !twoDigits(rest, 4, om) || oh > 23 || om > 59) return false;
            if (oh == 0 && om == 0) o ~= 'Z';
            else o ~= rest;
        }
        kind = Kind.offsetDateTime;
        text = o.idup;
        return true;
    }
    if (looksLikeTime(t))
    {
        size_t end;
        if (!checkTime(t, 0, end) || end != t.length) return false;
        appendTime(o, t);
        kind = Kind.localTime;
        text = o.idup;
        return true;
    }
    return false;
}
