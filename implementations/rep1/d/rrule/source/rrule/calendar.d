/**
 * Proleptic Gregorian calendar arithmetic on plain integer day numbers.
 *
 * A *day number* counts days from 0001-01-01, which is day 0 and a Monday.
 * Consequently the weekday of day number `n` is simply `n % 7`
 * (Monday = 0 … Sunday = 6), and conversions in both directions are O(1)
 * closed-form expressions.
 *
 * Nothing here relies on `std.datetime` or any other calendar library.
 */
module rrule.calendar;

/// Weekday numbers used throughout the library (`monday == 0`).
enum Weekday : ubyte
{
    monday = 0,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
}

/// A calendar date (proleptic Gregorian).
struct CivilDate
{
    /// Year, 1 and up.
    int year;
    /// Month, 1–12.
    int month;
    /// Day of month, 1–31.
    int day;
}

/// A floating (zone-less) local date and time of day.
struct LocalDateTime
{
    /// The calendar date.
    CivilDate date;
    /// Hour, 0–23.
    int hour;
    /// Minute, 0–59.
    int minute;
    /// Second, 0–59.
    int second;

    /// Seconds since local midnight.
    pure nothrow @nogc @safe int secondsOfDay() const
    {
        return hour * 3600 + minute * 60 + second;
    }
}

private static immutable int[13] cumulativeDays =
    [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365];

/// True if `year` is a leap year in the proleptic Gregorian calendar.
pure nothrow @nogc @safe bool isLeapYear(int year)
{
    return (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0);
}

/// Number of days in `year` (365 or 366).
pure nothrow @nogc @safe int yearLength(int year)
{
    return isLeapYear(year) ? 366 : 365;
}

/// Number of days in `month` (1–12) of `year`.
pure nothrow @nogc @safe int daysInMonth(int year, int month)
{
    if (month == 2)
        return isLeapYear(year) ? 29 : 28;
    return cumulativeDays[month] - cumulativeDays[month - 1];
}

/// Number of days in `year` that precede the first day of `month` (1–12).
pure nothrow @nogc @safe int daysBeforeMonth(int year, int month)
{
    return cumulativeDays[month - 1] + ((month > 2 && isLeapYear(year)) ? 1 : 0);
}

/// Day number of 1 January of `year`.
pure nothrow @nogc @safe int firstDayOfYear(int year)
{
    immutable y = year - 1;
    return 365 * y + y / 4 - y / 100 + y / 400;
}

/// Converts a civil date to a day number (0001-01-01 is day 0).
pure nothrow @nogc @safe int dayNumber(int year, int month, int day)
{
    return firstDayOfYear(year) + daysBeforeMonth(year, month) + day - 1;
}

/// ditto
pure nothrow @nogc @safe int dayNumber(CivilDate d)
{
    return dayNumber(d.year, d.month, d.day);
}

/// Weekday (Monday = 0) of a day number.
pure nothrow @nogc @safe int weekdayOf(int dayNum)
{
    return dayNum % 7;
}

/**
 * Converts a day number (`>= 0`) back to a civil date using the closed-form
 * 400-year-era algorithm.
 */
pure nothrow @nogc @safe CivilDate civilFromDayNumber(int dayNum)
{
    // Shift so that the epoch is 0000-03-01, making leap days fall at year end.
    immutable z = dayNum + 306;
    immutable era = z / 146_097;
    immutable doe = z - era * 146_097;
    immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    immutable mp = (5 * doy + 2) / 153;
    immutable day = doy - (153 * mp + 2) / 5 + 1;
    immutable month = mp < 10 ? mp + 3 : mp - 9;
    immutable year = yoe + era * 400 + (month <= 2 ? 1 : 0);
    return CivilDate(year, month, day);
}

/// True if the fields denote a real date with a year of at least 1.
pure nothrow @nogc @safe bool isValidDate(int year, int month, int day)
{
    return year >= 1 && month >= 1 && month <= 12 && day >= 1
        && day <= daysInMonth(year, month);
}
