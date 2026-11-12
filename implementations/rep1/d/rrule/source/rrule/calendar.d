/**
 * Proleptic Gregorian calendar arithmetic on integer day numbers.
 *
 * A *day number* counts days from 1 January 0001, which is day 0 and a
 * Monday. All conversions are closed-form (they use the 400-year cycle) and
 * work for any `long` day number that does not overflow, including dates
 * beyond year 9999.
 *
 * Weekdays are numbered Monday = 0 … Sunday = 6.
 */
module rrule.calendar;

@safe pure nothrow @nogc:

/// Weekday numbering used throughout the library.
enum Weekday : int
{
    monday = 0,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
}

/// A calendar date.
struct CivilDate
{
    /// Year (proleptic Gregorian, may be any integer).
    long year;
    /// Month, 1–12.
    int month;
    /// Day of month, 1–31.
    int day;
}

/// Floor division (rounds towards negative infinity). `b` must be positive.
long floorDiv(long a, long b)
{
    const q = a / b;
    return (a % b < 0) ? q - 1 : q;
}

/// Floor modulo; the result is in `0 .. b-1` for positive `b`.
long floorMod(long a, long b)
{
    const r = a % b;
    return r < 0 ? r + b : r;
}

/// Whether `year` is a Gregorian leap year.
bool isLeapYear(long year)
{
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

private static immutable int[13] monthLengths = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/// Number of days in `month` (1–12) of a year that is (`leap`) or is not a leap year.
int daysInMonth(int month, bool leap)
{
    return monthLengths[month] + (month == 2 && leap ? 1 : 0);
}

/// Number of days in `month` (1–12) of `year`.
int daysInMonth(long year, int month)
{
    return daysInMonth(month, isLeapYear(year));
}

/// Number of days in `year`: 365 or 366.
int daysInYear(long year)
{
    return isLeapYear(year) ? 366 : 365;
}

/// Day number of the given date. No validation is performed.
long daysFromCivil(long year, int month, int day)
{
    // Shift the year to start on 1 March so the leap day is the last day.
    const y = month <= 2 ? year - 1 : year;
    const era = floorDiv(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = month > 2 ? month - 3 : month + 9; // March = 0
    const doy = (153 * mp + 2) / 5 + day - 1; // [0, 365]
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    // 0000-03-01 is 306 days before 0001-01-01.
    return era * 146_097 + doe - 306;
}

/// Date of the given day number.
CivilDate civilFromDays(long days)
{
    const z = days + 306;
    const era = floorDiv(z, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp = (5 * doy + 2) / 153; // [0, 11]
    const d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    const m = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    return CivilDate(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d);
}

/// Weekday (0 = Monday … 6 = Sunday) of a day number.
int weekdayOf(long days)
{
    return cast(int) floorMod(days, 7);
}

/// 1-based day of the year of a date.
int dayOfYear(long year, int month, int day)
{
    return cast(int)(daysFromCivil(year, month, day) - daysFromCivil(year, 1, 1)) + 1;
}

///
unittest
{
    assert(daysFromCivil(1, 1, 1) == 0);
    assert(weekdayOf(0) == Weekday.monday);
    // 1 January 2000 was a Saturday.
    assert(weekdayOf(daysFromCivil(2000, 1, 1)) == Weekday.saturday);
    assert(civilFromDays(daysFromCivil(2024, 2, 29)) == CivilDate(2024, 2, 29));
}

unittest
{
    assert(isLeapYear(2000) && isLeapYear(2024) && isLeapYear(1600));
    assert(!isLeapYear(1900) && !isLeapYear(2023) && !isLeapYear(2100));
    assert(daysInMonth(2024, 2) == 29 && daysInMonth(2023, 2) == 28);
    assert(daysInMonth(2023, 12) == 31 && daysInMonth(2023, 4) == 30);
    assert(daysInYear(1900) == 365 && daysInYear(2000) == 366);
    assert(floorDiv(-1, 7) == -1 && floorMod(-1, 7) == 6 && floorMod(14, 7) == 0);
}

unittest
{
    // Known anchors.
    assert(daysFromCivil(1970, 1, 1) == 719_162);
    assert(weekdayOf(daysFromCivil(1970, 1, 1)) == Weekday.thursday);
    assert(weekdayOf(daysFromCivil(1997, 9, 2)) == Weekday.tuesday);
    assert(dayOfYear(2024, 12, 31) == 366 && dayOfYear(2023, 3, 1) == 60);
}

unittest
{
    // Round trip over a wide range, including before year 1 and far past year 9999,
    // checking that consecutive day numbers are consecutive calendar days.
    auto prev = civilFromDays(-1_000_000);
    foreach (d; -999_999 .. 4_000_000)
    {
        const cd = civilFromDays(d);
        assert(daysFromCivil(cd.year, cd.month, cd.day) == d);
        assert(cd.day >= 1 && cd.day <= daysInMonth(cd.year, cd.month));
        if (cd.day != 1)
            assert(cd.day == prev.day + 1 && cd.month == prev.month && cd.year == prev.year);
        else if (cd.month != 1)
            assert(prev.day == daysInMonth(prev.year, prev.month) && cd.month == prev.month + 1);
        else
            assert(cd.year == prev.year + 1 && prev.month == 12 && prev.day == 31);
        prev = cd;
    }
}
