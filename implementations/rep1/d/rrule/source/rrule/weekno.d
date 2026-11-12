/**
 * Week numbering for `BYWEEKNO` (python-dateutil / RFC 5545 conventions).
 *
 * Weeks start on a configurable weekday (`WKST`). Week 1 of a year is the
 * first week containing at least four days of that year.
 */
module rrule.weekno;

import rrule.calendar;

@safe pure nothrow @nogc:

/**
 * Day index (0-based from 1 January of `year`) on which week 1 starts.
 * Negative (-3 … -1) when week 1 begins in the previous December.
 */
int firstWeekStart(long year, int wkst)
{
    const jan1 = weekdayOf(daysFromCivil(year, 1, 1));
    const first = cast(int) floorMod(wkst - jan1, 7); // days to the first WKST
    return first < 4 ? first : first - 7;
}

/// Number of weeks (52 or 53) in `year`.
int weeksInYear(long year, int wkst)
{
    const l = daysInYear(year) - firstWeekStart(year, wkst);
    return l / 7 + (l % 7 >= 4 ? 1 : 0);
}

/// Week-numbering facts about one calendar year.
struct YearWeeks
{
    /// Day index on which week 1 starts (see `firstWeekStart`).
    int start;
    /// Number of weeks in the year.
    int weeks;
    /**
     * Week number assigned to the first days of January that precede week 1
     * (python-dateutil's numbering, which can be 53 even when the previous
     * year has only 52 weeks).
     */
    int leadingLabel;

    /// Computes the week facts of `year`.
    this(long year, int wkst) @safe pure nothrow @nogc
    {
        start = firstWeekStart(year, wkst);
        weeks = weeksInYear(year, wkst);
        if (firstWeekStart(year - 1, wkst) < 0)
            leadingLabel = weeksInYear(year - 1, wkst);
        else
            leadingLabel = 52 + ((daysInYear(year) - start) % 7 >= 4 ? 1 : 0);
    }

    /**
     * Whether the day with 0-based day-of-year index `index` matches a
     * `BYWEEKNO` selection, given as bit masks: bit `k` of `positive` is set
     * for the value `k`, bit `k` of `negative` for the value `-k`.
     */
    bool matches(int index, ulong positive, ulong negative) const @safe pure nothrow @nogc
    {
        if (index < start)
            return ((negative >> 1) & 1) != 0 || ((positive >> leadingLabel) & 1) != 0;
        const w = (index - start) / 7 + 1;
        if (w <= weeks)
            return ((positive >> w) & 1) != 0 || ((negative >> (weeks + 1 - w)) & 1) != 0;
        return ((positive >> 1) & 1) != 0;
    }
}

unittest
{
    // WKST=MO: 2015 has 53 weeks, 2011 has 52 but its leading days are labelled 53.
    assert(weeksInYear(2015, 0) == 53 && weeksInYear(2011, 0) == 52);
    assert(YearWeeks(2011, 0).leadingLabel == 53);
    assert(YearWeeks(2012, 0).leadingLabel == 52);
    assert(firstWeekStart(2011, 0) == 2); // Monday 3 January
    assert(firstWeekStart(2009, 0) == -3); // Monday 29 December 2008
    // 2 January 2011 (index 1) falls before week 1.
    const yw = YearWeeks(2011, 0);
    assert(yw.matches(1, 1UL << 53, 0));
    assert(!yw.matches(1, 1UL << 52, 0));
    assert(yw.matches(1, 0, 1UL << 1));
    // Last days of December 2008 belong to week 1 of 2009.
    const y8 = YearWeeks(2008, 0);
    assert(y8.matches(365, 1UL << 1, 0));
    assert(!y8.matches(365, 0, 1UL << 1));
}
