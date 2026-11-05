/// Unit tests for `rrule.calendar` and `rrule.timestamp`.
module calendar_test;

import rrule.calendar;
import rrule.errors;
import rrule.timestamp;

import std.exception : assertThrown;

unittest // leap years
{
    assert(isLeapYear(2000));
    assert(isLeapYear(2024));
    assert(!isLeapYear(1900));
    assert(!isLeapYear(2023));
    assert(yearLength(2100) == 365);
    assert(daysInMonth(2024, 2) == 29);
    assert(daysInMonth(2023, 2) == 28);
    assert(daysInMonth(2023, 12) == 31);
    assert(daysInMonth(2023, 4) == 30);
}

unittest // anchors from the specification
{
    assert(dayNumber(1, 1, 1) == 0);
    assert(weekdayOf(dayNumber(1, 1, 1)) == Weekday.monday);
    assert(weekdayOf(dayNumber(2000, 1, 1)) == Weekday.saturday);
    assert(weekdayOf(dayNumber(1997, 9, 2)) == Weekday.tuesday);
    assert(dayNumber(10_000, 1, 1) == firstDayOfYear(10_000));
}

unittest // round trip over a wide range of days
{
    int prev = dayNumber(1000, 1, 1) - 1;
    foreach (n; dayNumber(1000, 1, 1) .. dayNumber(1000, 1, 1) + 800_000)
    {
        auto d = civilFromDayNumber(n);
        assert(isValidDate(d.year, d.month, d.day));
        assert(dayNumber(d) == n);
        assert(n == prev + 1);
        prev = n;
    }
    auto last = civilFromDayNumber(dayNumber(9999, 12, 31));
    assert(last == CivilDate(9999, 12, 31));
    assert(civilFromDayNumber(dayNumber(2024, 2, 29)) == CivilDate(2024, 2, 29));
    assert(civilFromDayNumber(0) == CivilDate(1, 1, 1));
}

unittest // date validation
{
    assert(isValidDate(2024, 2, 29));
    assert(!isValidDate(2023, 2, 29));
    assert(!isValidDate(2023, 13, 1));
    assert(!isValidDate(2023, 4, 31));
}

unittest // timestamps
{
    auto dt = parseTimestamp("19970902T090507");
    assert(dt.date == CivilDate(1997, 9, 2));
    assert(dt.hour == 9 && dt.minute == 5 && dt.second == 7);
    assert(dt.secondsOfDay == 9 * 3600 + 5 * 60 + 7);
    assert(formatTimestamp(dt) == "19970902T090507");
    assert(formatTimestamp(parseTimestamp("99991231T235959")) == "99991231T235959");
    assertThrown!RRuleException(parseTimestamp("19970230T090000"));
    assertThrown!RRuleException(parseTimestamp("19970902 090000"));
    assertThrown!RRuleException(parseTimestamp("19970902T240000"));
    assertThrown!RRuleException(parseTimestamp("1997"));
}
