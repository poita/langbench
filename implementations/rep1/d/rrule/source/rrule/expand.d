/**
 * Expansion of a recurrence rule into its occurrences.
 *
 * The rule is evaluated period by period (a year, a month, a week or a day,
 * depending on `FREQ`). Every candidate day of every period is tested against
 * every filter in constant time, `BYSETPOS` selects among the kept days, and
 * the results are emitted in chronological order until `COUNT`, `UNTIL` or the
 * year-9999 bound is reached. No attempt is made to skip periods that cannot
 * match.
 */
module rrule.expand;

import rrule.calendar;
import rrule.datetime;
import rrule.rule;
import rrule.weekno;

/// The last year for which periods are enumerated.
enum int maxYear = 9999;

private enum int maxPeriodDays = 366;
private enum long secondsPerDay = 86_400;

/**
 * Lazily expands a `Rule` starting at `dtstart`; an input range of
 * `LocalDateTime`.
 *
 * It is a class so that copies of the range share one iteration state.
 */
final class Occurrences
{
    // Rule parameters.
    private Freq freq;
    private int interval;
    private int count;
    private bool hasUntil;
    private long untilKey;
    private int wkst;

    // DTSTART.
    private long startDay;
    private int startTod;
    private long startYear;
    private int startMonth;
    private int weekOffset; // days from the week start (WKST) to DTSTART

    // Filters (after the DTSTART defaults).
    private bool hasMonth, hasMonthDay, hasYearDay, hasWeekNo, hasPlainDay, hasOrdinal;
    private uint monthMask; // bit m: month m
    private uint monthDayPos, monthDayNeg; // bit k: day k / day -k
    private bool[367] yearDayPos, yearDayNeg; // index k: day k / day -k
    private ulong weekNoPos, weekNoNeg; // bit k: week k / week -k
    private uint plainDayMask; // bit d: weekday d
    private ulong[7] ordinalPos, ordinalNeg; // per weekday, bit n: n-th / n-th from last
    private bool ordinalInMonth; // ordinals count within the month, else within the year
    private int[] setPos;

    // Iteration state.
    private long period;
    private bool finished;
    private long printed;
    private long cachedWeekYear = long.min;
    private YearWeeks yearWeeks;
    private long[maxPeriodDays + 1] cand; // kept days of the current period
    private bool[maxPeriodDays + 1] mark;
    private int candCount;
    private long[maxPeriodDays + 1] ready; // occurrences waiting to be consumed
    private int readyCount, readyPos;

    /// Prepares the expansion of `rule` from `dtstart`.
    this(LocalDateTime dtstart, Rule rule)
    {
        freq = rule.freq;
        interval = rule.interval;
        count = rule.count;
        wkst = rule.weekStart;
        startDay = dtstart.dayNumber;
        startTod = dtstart.secondOfDay;
        startYear = dtstart.year;
        startMonth = dtstart.month;
        const startWd = weekdayOf(startDay);
        weekOffset = cast(int) floorMod(startWd - wkst, 7);
        hasUntil = rule.hasUntil;
        if (hasUntil)
            untilKey = rule.until.dayNumber * secondsPerDay + rule.until.secondOfDay;
        setPos = rule.bySetPos;

        // Defaults derived from DTSTART.
        if (rule.byMonthDay.length == 0 && rule.byYearDay.length == 0
            && rule.byWeekNo.length == 0 && rule.byDay.length == 0)
        {
            final switch (freq)
            {
            case Freq.yearly:
                if (rule.byMonth.length == 0)
                    rule.byMonth = [dtstart.month];
                rule.byMonthDay = [dtstart.day];
                break;
            case Freq.monthly:
                rule.byMonthDay = [dtstart.day];
                break;
            case Freq.weekly:
                rule.byDay = [ByDay(startWd, 0)];
                break;
            case Freq.daily:
                break;
            }
        }

        hasMonth = rule.byMonth.length != 0;
        foreach (m; rule.byMonth)
            monthMask |= 1u << m;
        hasMonthDay = rule.byMonthDay.length != 0;
        foreach (v; rule.byMonthDay)
        {
            if (v > 0)
                monthDayPos |= 1u << v;
            else
                monthDayNeg |= 1u << -v;
        }
        hasYearDay = rule.byYearDay.length != 0;
        foreach (v; rule.byYearDay)
        {
            if (v > 0)
                yearDayPos[v] = true;
            else
                yearDayNeg[-v] = true;
        }
        hasWeekNo = rule.byWeekNo.length != 0;
        foreach (v; rule.byWeekNo)
        {
            if (v > 0)
                weekNoPos |= 1UL << v;
            else
                weekNoNeg |= 1UL << -v;
        }
        foreach (b; rule.byDay)
        {
            if (b.ordinal == 0)
            {
                hasPlainDay = true;
                plainDayMask |= 1u << b.weekday;
            }
            else
            {
                hasOrdinal = true;
                if (b.ordinal > 0)
                    ordinalPos[b.weekday] |= 1UL << b.ordinal;
                else
                    ordinalNeg[b.weekday] |= 1UL << -b.ordinal;
            }
        }
        ordinalInMonth = freq == Freq.monthly || hasMonth;

        fill();
    }

    /// True when there are no more occurrences.
    bool empty() const
    {
        return readyPos >= readyCount;
    }

    /// The current occurrence. Must not be called when `empty`.
    LocalDateTime front() const
    in (!empty)
    {
        return LocalDateTime.fromDayAndSecond(ready[readyPos], startTod);
    }

    /// Advances to the next occurrence.
    void popFront()
    in (!empty)
    {
        if (++readyPos >= readyCount)
            fill();
    }

    // Enumerates periods until at least one occurrence is ready or the rule is exhausted.
    private void fill()
    {
        readyCount = 0;
        readyPos = 0;
        while (!finished && readyCount == 0)
        {
            long pStart;
            int pLen;
            if (!nextPeriod(pStart, pLen))
            {
                finished = true;
                break;
            }
            if (hasUntil && pStart * secondsPerDay + startTod > untilKey)
            {
                finished = true;
                break;
            }
            scan(pStart, pLen);
            select();
            emit();
        }
    }

    // Start and length of the next period; false once it starts after year 9999.
    private bool nextPeriod(out long pStart, out int pLen)
    {
        enum lastDay = daysFromCivil(maxYear, 12, 31);
        const k = period++;
        final switch (freq)
        {
        case Freq.yearly:
            const year = startYear + k * interval;
            if (year > maxYear)
                return false;
            pStart = daysFromCivil(year, 1, 1);
            pLen = daysInYear(year);
            return true;
        case Freq.monthly:
            const index = startYear * 12 + (startMonth - 1) + k * interval;
            const year = index / 12;
            if (year > maxYear)
                return false;
            const month = cast(int)(index % 12) + 1;
            pStart = daysFromCivil(year, month, 1);
            pLen = daysInMonth(year, month);
            return true;
        case Freq.weekly:
            if (k == 0)
            {
                pStart = startDay;
                pLen = 7 - weekOffset;
                return true;
            }
            pStart = startDay - weekOffset + 7 * k * interval;
            pLen = 7;
            return pStart <= lastDay;
        case Freq.daily:
            pStart = startDay + k * interval;
            pLen = 1;
            return pStart <= lastDay;
        }
    }

    // Tests the `pLen` days from `pStart` against the filters and stores the kept ones in `cand`.
    private void scan(long pStart, int pLen)
    {
        candCount = 0;
        const first = civilFromDays(pStart);
        long year = first.year;
        int month = first.month;
        int day = first.day;
        bool leap = isLeapYear(year);
        int yearLen = leap ? 366 : 365;
        int monthLen = daysInMonth(month, leap);
        int yday = cast(int)(pStart - daysFromCivil(year, 1, 1)) + 1;
        int wd = weekdayOf(pStart);
        if (hasWeekNo && cachedWeekYear != year)
        {
            cachedWeekYear = year;
            yearWeeks = YearWeeks(year, wkst);
        }

        foreach (i; 0 .. pLen)
        {
            bool keep = (!hasMonth || ((monthMask >> month) & 1))
                && (!hasMonthDay || ((monthDayPos >> day) & 1)
                        || ((monthDayNeg >> (monthLen + 1 - day)) & 1))
                && (!hasYearDay || yearDayPos[yday] || yearDayNeg[yearLen + 1 - yday])
                && (!hasWeekNo || yearWeeks.matches(yday - 1, weekNoPos, weekNoNeg))
                && (!hasPlainDay || ((plainDayMask >> wd) & 1))
                && (!hasOrdinal || ordinalMatches(wd, day, monthLen, yday, yearLen));
            if (keep)
                cand[candCount++] = pStart + i;

            // Move to the next day.
            wd = wd == 6 ? 0 : wd + 1;
            ++yday;
            if (++day > monthLen)
            {
                day = 1;
                if (++month > 12)
                {
                    month = 1;
                    ++year;
                    yday = 1;
                    leap = isLeapYear(year);
                    yearLen = leap ? 366 : 365;
                    if (hasWeekNo && i + 1 < pLen)
                    {
                        cachedWeekYear = year;
                        yearWeeks = YearWeeks(year, wkst);
                    }
                }
                monthLen = daysInMonth(month, leap);
            }
        }
    }

    // Whether an ordinal BYDAY code designates this day.
    private bool ordinalMatches(int wd, int day, int monthLen, int yday, int yearLen) const
    {
        // The n-th `wd` of a range is the day at offset 7(n-1)..7(n-1)+6 from its start.
        const offset = ordinalInMonth ? day - 1 : yday - 1;
        const length = ordinalInMonth ? monthLen : yearLen;
        const n = offset / 7 + 1;
        const fromEnd = (length - 1 - offset) / 7 + 1;
        return ((ordinalPos[wd] >> n) & 1) != 0 || ((ordinalNeg[wd] >> fromEnd) & 1) != 0;
    }

    // Applies BYSETPOS to the kept days of the period.
    private void select()
    {
        if (setPos.length == 0)
            return;
        mark[0 .. candCount] = false;
        foreach (p; setPos)
        {
            const index = p > 0 ? p - 1 : candCount + p;
            if (index >= 0 && index < candCount)
                mark[index] = true;
        }
        int n;
        foreach (i; 0 .. candCount)
            if (mark[i])
                cand[n++] = cand[i];
        candCount = n;
    }

    // Applies UNTIL / DTSTART / COUNT to the period's occurrences.
    private void emit()
    {
        foreach (day; cand[0 .. candCount])
        {
            if (hasUntil && day * secondsPerDay + startTod > untilKey)
            {
                finished = true;
                return;
            }
            if (day < startDay)
                continue;
            ready[readyCount++] = day;
            if (count != 0 && ++printed >= count)
            {
                finished = true;
                return;
            }
        }
    }
}

/**
 * Returns the first `limit` occurrences of `rule` (fewer if the rule ends
 * sooner) for a series starting at `dtstart`.
 */
LocalDateTime[] expand(LocalDateTime dtstart, Rule rule, size_t limit = size_t.max)
{
    LocalDateTime[] result;
    auto occ = new Occurrences(dtstart, rule);
    for (; result.length < limit && !occ.empty; occ.popFront())
        result ~= occ.front;
    return result;
}

version (unittest)
{
    private string[] run(string start, string rule, size_t limit = size_t.max)
    {
        string[] r;
        foreach (t; expand(LocalDateTime.parse(start), parseRule(rule), limit))
            r ~= t.toString;
        return r;
    }
}

///
unittest
{
    assert(run("19970902T090000", "FREQ=DAILY;COUNT=3") ==
            ["19970902T090000", "19970903T090000", "19970904T090000"]);
}

unittest
{
    // Worked examples of the specification.
    assert(run("19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10", 100) ==
            ["19970926T090000", "19971128T090000", "19980130T090000", "19980327T090000",
            "19980529T090000", "19980731T090000", "19980925T090000", "19981127T090000",
            "19990129T090000", "19990326T090000"]);
    assert(run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8", 100) ==
            ["19970902T090000", "19970904T090000", "19970916T090000", "19970918T090000",
            "19970930T090000", "19971002T090000", "19971014T090000", "19971016T090000"]);
    assert(run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4) ==
            ["19970902T090000", "19970907T090000", "19970916T090000", "19970921T090000"]);
}

unittest
{
    assert(run("20240229T120000", "FREQ=YEARLY;COUNT=3", 10) ==
            ["20240229T120000", "20280229T120000", "20320229T120000"]);
    assert(run("20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000", 10) ==
            ["20240131T000000", "20240229T000000", "20240331T000000", "20240430T000000"]);
    assert(run("20240301T080000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", 10) ==
            ["20240329T080000", "20240430T080000", "20240531T080000"]);
    assert(run("20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5", 10).length == 0);
}

unittest
{
    assert(run("20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3", 10) ==
            ["20201228T000000", "20261228T000000", "20321227T000000"]);
    assert(run("20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4", 10) ==
            ["20110101T000000", "20110102T000000", "20151228T000000", "20151229T000000"]);
}

unittest
{
    // Defaults derived from DTSTART.
    assert(run("20240131T000000", "FREQ=MONTHLY;COUNT=3") ==
            ["20240131T000000", "20240331T000000", "20240531T000000"]);
    assert(run("20240110T000000", "FREQ=WEEKLY;COUNT=3") ==
            ["20240110T000000", "20240117T000000", "20240124T000000"]);
    assert(run("20240115T000000", "FREQ=MONTHLY;BYSETPOS=1;COUNT=2") ==
            ["20240115T000000", "20240215T000000"]);
    assert(run("20240115T000000", "FREQ=MONTHLY;BYSETPOS=2;COUNT=2").length == 0);
    // BYSETPOS is applied before the DTSTART check.
    assert(run("20240120T000000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2") ==
            ["20240205T000000", "20240304T000000"]);
}

unittest
{
    // UNTIL is inclusive and may precede DTSTART.
    assert(run("20240101T000000", "FREQ=DAILY;UNTIL=20240103T000000") ==
            ["20240101T000000", "20240102T000000", "20240103T000000"]);
    assert(run("20240101T120000", "FREQ=DAILY;UNTIL=20240103T115959") ==
            ["20240101T120000", "20240102T120000"]);
    assert(run("20240101T000000", "FREQ=DAILY;UNTIL=20231231T000000").length == 0);
}

unittest
{
    // Ordinals: yearly with and without BYMONTH.
    assert(run("20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4") ==
            ["20240108T000000", "20240708T000000", "20250113T000000", "20250714T000000"]);
    assert(run("20240101T000000", "FREQ=YEARLY;BYDAY=20MO;COUNT=2") ==
            ["20240513T000000", "20250519T000000"]);
    assert(run("20240101T000000", "FREQ=YEARLY;BYDAY=-1SU;COUNT=2") ==
            ["20241229T000000", "20251228T000000"]);
    // A fifth Monday exists only in some months.
    assert(run("20240101T000000", "FREQ=MONTHLY;BYDAY=5MO;COUNT=3") ==
            ["20240129T000000", "20240429T000000", "20240729T000000"]);
}

unittest
{
    // BYYEARDAY, negative and positive.
    assert(run("20240101T000000", "FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=4") ==
            ["20240101T000000", "20241231T000000", "20250101T000000", "20251231T000000"]);
    assert(run("20240101T000000", "FREQ=YEARLY;BYYEARDAY=366;COUNT=2") ==
            ["20241231T000000", "20281231T000000"]);
}

unittest
{
    // Year 9999 bound: the expansion ends rather than overflowing.
    assert(run("99980101T000000", "FREQ=YEARLY;COUNT=10") ==
            ["99980101T000000", "99990101T000000"]);
    assert(run("99991230T000000", "FREQ=DAILY;COUNT=10") ==
            ["99991230T000000", "99991231T000000"]);
    assert(run("99991201T000000", "FREQ=WEEKLY;INTERVAL=100;COUNT=5") ==
            ["99991201T000000"]);
    assert(run("10000101T000000", "FREQ=WEEKLY;BYMONTH=2;BYMONTHDAY=30", 3).length == 0);
}

unittest
{
    // WEEKLY periods may cross month and year boundaries.
    assert(run("20231228T000000", "FREQ=WEEKLY;BYDAY=MO,SA;COUNT=4") ==
            ["20231230T000000", "20240101T000000", "20240106T000000", "20240108T000000"]);
}

unittest
{
    // The range interface and `limit`.
    auto occ = new Occurrences(LocalDateTime.parse("20240101T000000"), parseRule("FREQ=DAILY"));
    assert(!occ.empty && occ.front.toString == "20240101T000000");
    occ.popFront();
    assert(occ.front.toString == "20240102T000000");
    assert(expand(LocalDateTime.parse("20240101T000000"), parseRule("FREQ=DAILY"), 5).length == 5);
}
