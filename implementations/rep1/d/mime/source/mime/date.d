/// `Date` header parsing and UTC conversion.
module mime.date;

import mime.ascii;
import mime.buffer;
import mime.syntax;

/// A successfully parsed date.
struct ParsedDate
{
    long epoch; /// seconds since 1970-01-01T00:00:00Z
    int offsetMinutes; /// zone offset in minutes
}

/// Days from 1970-01-01 to the civil date (negative before it).
long daysFromCivil(long y, int m, int d) @safe pure nothrow @nogc
{
    y -= m <= 2;
    immutable era = (y >= 0 ? y : y - 399) / 400;
    immutable yoe = y - era * 400;
    immutable doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    immutable doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

/// Inverse of `daysFromCivil`.
void civilFromDays(long z, out long y, out int m, out int d) @safe pure nothrow @nogc
{
    z += 719_468;
    immutable era = (z >= 0 ? z : z - 146_096) / 146_097;
    immutable doe = z - era * 146_097;
    immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    y = yoe + era * 400;
    immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    immutable mp = (5 * doy + 2) / 153;
    d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    m = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    if (m <= 2)
        y++;
}

private long floorDiv(long a, long b) @safe pure nothrow @nogc
{
    long q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0)))
        q--;
    return q;
}

private bool isLeap(long y) @safe pure nothrow @nogc
{
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

private int daysInMonth(long y, int m) @safe pure nothrow @nogc
{
    static immutable int[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return m == 2 && isLeap(y) ? 29 : days[m - 1];
}

private bool allDigits(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (!isDigit(c))
            return false;
    return true;
}

private int toInt(const(char)[] s) @safe pure nothrow @nogc
{
    int r = 0;
    foreach (c; s)
        r = r * 10 + (c - '0');
    return r;
}

private int monthNumber(const(char)[] s) @safe pure nothrow @nogc
{
    static immutable string[12] names = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ];
    foreach (i, n; names)
        if (equalsLower(s, n))
            return cast(int) i + 1;
    return 0;
}

private bool zoneOffset(const(char)[] s, out int minutes) @safe pure nothrow @nogc
{
    minutes = 0;
    if (s.length == 5 && (s[0] == '+' || s[0] == '-') && allDigits(s[1 .. 5]))
    {
        immutable v = toInt(s[1 .. 3]) * 60 + toInt(s[3 .. 5]);
        minutes = s[0] == '-' ? -v : v;
        return true;
    }
    struct Zone
    {
        string name;
        int minutes;
    }

    static immutable Zone[11] zones = [
        Zone("ut", 0), Zone("gmt", 0), Zone("z", 0), Zone("est", -300),
        Zone("edt", -240), Zone("cst", -360), Zone("cdt", -300),
        Zone("mst", -420), Zone("mdt", -360), Zone("pst", -480), Zone("pdt", -420)
    ];
    foreach (z; zones)
        if (equalsLower(s, z.name))
        {
            minutes = z.minutes;
            return true;
        }
    return false;
}

/// Parses a `Date` header's unfolded raw value. Returns false when invalid.
bool parseDate(const(char)[] raw, out ParsedDate result) @safe pure nothrow
{
    // 1. remove comments
    auto clean = ByteBuffer(raw.length);
    for (size_t i = 0; i < raw.length;)
    {
        if (raw[i] == '(')
            i = skipComment(raw, i);
        else
            clean.put(raw[i++]);
    }
    const(char)[] s = (() @trusted => cast(const(char)[]) clean.data)();

    // 2. tokenise on SPACE, TAB and ','
    const(char)[][] toks;
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && (isBlank(s[i]) || s[i] == ','))
            i++;
        immutable st = i;
        while (i < s.length && !isBlank(s[i]) && s[i] != ',')
            i++;
        if (i > st)
            toks ~= s[st .. i];
    }
    // 3. optional weekday
    if (toks.length > 0)
        foreach (w; ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
            if (equalsLower(toks[0], w))
            {
                toks = toks[1 .. $];
                break;
            }
    if (toks.length < 4)
        return false;

    // day
    auto dayTok = toks[0];
    if (dayTok.length < 1 || dayTok.length > 2 || !allDigits(dayTok))
        return false;
    immutable day = toInt(dayTok);
    if (day < 1 || day > 31)
        return false;
    // month
    immutable month = monthNumber(toks[1]);
    if (month == 0)
        return false;
    // year
    auto yearTok = toks[2];
    if (yearTok.length < 2 || yearTok.length > 4 || !allDigits(yearTok))
        return false;
    long year = toInt(yearTok);
    if (yearTok.length == 2)
        year += year >= 50 ? 1900 : 2000;
    else if (yearTok.length == 3)
        year += 1900;
    if (year < 1 || year > 9999)
        return false;
    // time
    auto timeTok = toks[3];
    int[3] hms = [0, 0, 0];
    {
        size_t field = 0;
        size_t st = 0;
        foreach (k; 0 .. timeTok.length + 1)
        {
            if (k == timeTok.length || timeTok[k] == ':')
            {
                auto part = timeTok[st .. k];
                if (field >= 3 || part.length < 1 || part.length > 2 || !allDigits(part))
                    return false;
                hms[field++] = toInt(part);
                st = k + 1;
            }
        }
        if (field < 2)
            return false;
    }
    if (hms[0] > 23 || hms[1] > 59 || hms[2] > 60)
        return false;
    int offset = 0;
    if (toks.length >= 5)
        zoneOffset(toks[4], offset);
    // 5. calendar validity
    if (day > daysInMonth(year, month))
        return false;

    immutable days = daysFromCivil(year, month, day);
    result.epoch = days * 86_400 + hms[0] * 3600 + hms[1] * 60 + hms[2] - cast(long) offset * 60;
    result.offsetMinutes = offset;
    return true;
}

/// Appends `YYYY-MM-DDTHH:MM:SSZ` for the UTC time of `epoch`.
void putUtc(ref ByteBuffer o, long epoch) @safe pure nothrow
{
    immutable days = floorDiv(epoch, 86_400);
    immutable tod = epoch - days * 86_400;
    long y;
    int m, d;
    civilFromDays(days, y, m, d);
    o.putUint(cast(ulong) y, 4);
    o.put('-');
    o.putUint(m, 2);
    o.put('-');
    o.putUint(d, 2);
    o.put('T');
    o.putUint(tod / 3600, 2);
    o.put(':');
    o.putUint(tod / 60 % 60, 2);
    o.put(':');
    o.putUint(tod % 60, 2);
    o.put('Z');
}

/// Appends the zone offset as sign plus at-least-two-digit hours and minutes.
void putOffset(ref ByteBuffer o, int offsetMinutes) @safe pure nothrow
{
    immutable a = offsetMinutes < 0 ? -offsetMinutes : offsetMinutes;
    o.put(offsetMinutes < 0 ? '-' : '+');
    o.putUint(a / 60, 2);
    o.putUint(a % 60, 2);
}
