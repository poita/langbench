/// `Date` header parsing and closed-form calendar arithmetic.
module mime.date;

import std.array : appender;
import mime.text;

@safe:

/// Result of parsing a `Date` header.
struct ParsedDate
{
    bool valid;           /// whether the header held a usable date
    long epoch;           /// seconds since 1970-01-01T00:00:00Z
    int offsetMinutes;    /// the zone offset in minutes
    /// `YYYY-MM-DDTHH:MM:SSZ` rendering of `epoch` (valid dates only).
    string utc() const pure nothrow { return formatUtc(epoch); }
    /// `±HHMM` rendering of the offset.
    string offset() const pure nothrow { return formatOffset(offsetMinutes); }
}

/// Floor division for possibly negative numerators.
long floorDiv(long a, long b) pure nothrow @nogc
{
    long q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0)))
        --q;
    return q;
}

/// Days from 1970-01-01 to the given proleptic Gregorian date.
long daysFromCivil(long y, int m, int d) pure nothrow @nogc
{
    y -= m <= 2 ? 1 : 0;
    const era = floorDiv(y, 400);
    const yoe = y - era * 400;
    const doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

/// Inverse of `daysFromCivil`.
void civilFromDays(long z, out long year, out int month, out int day) pure nothrow @nogc
{
    z += 719_468;
    const era = floorDiv(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    day = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    month = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    year = yoe + era * 400 + (month <= 2 ? 1 : 0);
}

private string pad(long v, size_t width) pure nothrow
{
    import std.conv : to;
    auto s = v.to!string;
    while (s.length < width)
        s = "0" ~ s;
    return s;
}

/// Formats an epoch as `YYYY-MM-DDTHH:MM:SSZ`.
string formatUtc(long epoch) pure nothrow
{
    const days = floorDiv(epoch, 86_400);
    const tod = epoch - days * 86_400;
    long y;
    int mo, d;
    civilFromDays(days, y, mo, d);
    return pad(y, 4) ~ "-" ~ pad(mo, 2) ~ "-" ~ pad(d, 2) ~ "T"
        ~ pad(tod / 3600, 2) ~ ":" ~ pad(tod / 60 % 60, 2) ~ ":" ~ pad(tod % 60, 2) ~ "Z";
}

/// Formats an offset in minutes as sign, hours and minutes (each at least
/// two digits).
string formatOffset(int minutes) pure nothrow
{
    const a = minutes < 0 ? -minutes : minutes;
    return (minutes < 0 ? "-" : "+") ~ pad(a / 60, 2) ~ pad(a % 60, 2);
}

private bool allDigits(string s) pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (char c; s)
        if (c < '0' || c > '9')
            return false;
    return true;
}

private int number(string s) pure nothrow @nogc
{
    int v = 0;
    foreach (char c; s)
        v = v * 10 + (c - '0');
    return v;
}

private bool isLeap(long y) pure nothrow @nogc
{
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

private int daysInMonth(long y, int m) pure nothrow @nogc
{
    static immutable int[12] table = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return (m == 2 && isLeap(y)) ? 29 : table[m - 1];
}

private immutable string[12] monthNames =
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
private immutable string[7] dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

private bool zoneOffset(string z, out int minutes) pure nothrow
{
    minutes = 0;
    if (z.length == 5 && (z[0] == '+' || z[0] == '-') && allDigits(z[1 .. $]))
    {
        const v = number(z[1 .. 3]) * 60 + number(z[3 .. 5]);
        minutes = z[0] == '-' ? -v : v;
        return true;
    }
    switch (toLowerAscii(z))
    {
    case "ut", "gmt", "z": minutes = 0; return true;
    case "est": minutes = -300; return true;
    case "edt": minutes = -240; return true;
    case "cst": minutes = -360; return true;
    case "cdt": minutes = -300; return true;
    case "mst": minutes = -420; return true;
    case "mdt": minutes = -360; return true;
    case "pst": minutes = -480; return true;
    case "pdt": minutes = -420; return true;
    default: return false;
    }
}

/// Parses the raw (unfolded) value of a `Date` header.
ParsedDate parseDate(string raw) pure nothrow
{
    // 1. remove comments
    auto app = appender!string();
    size_t i = 0;
    while (i < raw.length)
    {
        if (raw[i] == '(')
            i = skipComment(raw, i);
        else
            app.put(raw[i++]);
    }
    const cleaned = app.data;
    // 2. tokenise on SPACE, TAB and ','
    string[] tokens;
    size_t start = 0;
    foreach (k, char c; cleaned)
    {
        if (isBlank(c) || c == ',')
        {
            if (k > start)
                tokens ~= cleaned[start .. k];
            start = k + 1;
        }
    }
    if (cleaned.length > start)
        tokens ~= cleaned[start .. $];
    // 3. optional day of week
    if (tokens.length != 0)
        foreach (dn; dayNames)
            if (toLowerAscii(tokens[0]) == dn)
            {
                tokens = tokens[1 .. $];
                break;
            }
    ParsedDate bad;
    if (tokens.length < 4)
        return bad;

    // day
    const dayTok = tokens[0];
    if (!allDigits(dayTok) || dayTok.length > 2)
        return bad;
    const day = number(dayTok);
    if (day < 1 || day > 31)
        return bad;
    // month
    int month = 0;
    if (tokens[1].length == 3)
        foreach (k, mn; monthNames)
            if (toLowerAscii(tokens[1]) == mn)
                month = cast(int) k + 1;
    if (month == 0)
        return bad;
    // year
    const yearTok = tokens[2];
    if (!allDigits(yearTok) || yearTok.length < 2 || yearTok.length > 4)
        return bad;
    long year = number(yearTok);
    if (yearTok.length == 2)
        year += year >= 50 ? 1900 : 2000;
    else if (yearTok.length == 3)
        year += 1900;
    if (year < 1 || year > 9999)
        return bad;
    // time
    string[3] fields;
    size_t nf = 0;
    size_t fs = 0;
    const timeTok = tokens[3];
    foreach (k; 0 .. timeTok.length + 1)
    {
        if (k == timeTok.length || timeTok[k] == ':')
        {
            if (nf == 3)
                return bad;
            fields[nf++] = timeTok[fs .. k];
            fs = k + 1;
        }
    }
    if (nf < 2)
        return bad;
    foreach (f; fields[0 .. nf])
        if (!allDigits(f) || f.length > 2)
            return bad;
    const hh = number(fields[0]);
    const mm = number(fields[1]);
    const ss = nf == 3 ? number(fields[2]) : 0;
    if (hh > 23 || mm > 59 || ss > 60)
        return bad;
    // zone
    int offset = 0;
    if (tokens.length >= 5)
        zoneOffset(tokens[4], offset);
    // 5. calendar check
    if (day > daysInMonth(year, month))
        return bad;

    ParsedDate r;
    r.valid = true;
    r.offsetMinutes = offset;
    r.epoch = daysFromCivil(year, month, day) * 86_400 + hh * 3600 + mm * 60 + ss - cast(long) offset * 60;
    return r;
}

pure nothrow unittest
{
    void check(string raw, long epoch, string utc, string off)
    {
        const d = parseDate(raw);
        assert(d.valid, raw);
        assert(d.epoch == epoch, raw);
        assert(d.utc == utc, raw);
        assert(d.offset == off, raw);
    }
    check("Sun, 29 Feb 2004 22:03:22 -0800", 1078121002, "2004-03-01T06:03:22Z", "-0800");
    check("3 Jan 70 00:00:00 GMT", 172800, "1970-01-03T00:00:00Z", "+0000");
    check("Tue, 1 Jan 2036 00:00:60 +0000", 2082758460, "2036-01-01T00:01:00Z", "+0000");
    check("Mon, 3 Mar 1969 12:00 (GMT) -0500", -26204400, "1969-03-03T17:00:00Z", "-0500");
    check("Sun, 07 Mar 2004 15:21:26 -0000", 1078672886, "2004-03-07T15:21:26Z", "+0000");
    check("1 Jan 2000 00:00:00 +2359", 946598460, "1999-12-31T00:01:00Z", "+2359");
    check("1 Jan 2000 00:00 +9999", 946684800 - 6039 * 60, "1999-12-27T19:21:00Z", "+10039");
    assert(!parseDate("not a date").valid);
    assert(!parseDate("30 Feb 2001 10:00 +0000").valid);
    assert(!parseDate("1 Jan 0000 10:00").valid);
    assert(parseDate("1 Jan 2000 10:00 XYZ").offsetMinutes == 0);
    assert(parseDate("1 Jan 2000 10:00 est").offsetMinutes == -300);
}
