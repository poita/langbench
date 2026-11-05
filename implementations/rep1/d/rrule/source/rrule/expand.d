/**
 * Recurrence expansion.
 *
 * The rule is evaluated period by period (a year, month, week or day,
 * depending on `FREQ`). Each period supplies an ordered run of candidate
 * days; every candidate is tested against the rule's filters with O(1)
 * table lookups, the surviving days optionally go through `BYSETPOS`, and
 * the results are handed to a sink, one day number at a time.
 *
 * All scratch storage lives inside the `Expander` and is reused, so
 * expanding many rules with one `Expander` performs no allocation.
 */
module rrule.expand;

import rrule.calendar;
import rrule.rule;

/// Last year for which occurrences are generated.
enum lastYear = 9999;

/**
 * Reusable rule expander.
 *
 * A sink is any type with a method `void put(int dayNumber)`; it receives the
 * day number of each occurrence in chronological order (the time of day is the
 * one of DTSTART).
 */
struct Expander
{
    private Rule plan;
    private int[366] kept;
    private bool[366] ordinalMask;
    private bool[366] selected;
    private int dtDay;
    private int lastDay;
    private size_t emitted;
    private size_t limit;
    private bool done;
    // Week numbering data for the YEARLY period's year (BYWEEKNO).
    private int weekStart0;
    private int weekCount;
    private bool beforeWeekOne;

    /**
     * Expands `rule` from `start`, passing at most `maxCount` occurrences
     * (and no more than the rule's own `COUNT`) to `sink`.
     *
     * Returns: the number of occurrences produced.
     */
    size_t expand(Sink)(Rule rule, LocalDateTime start, size_t maxCount, ref Sink sink)
    {
        plan = rule;
        applyDefaults(plan, start.date);
        limit = maxCount;
        if (plan.hasCount && plan.count < limit)
            limit = plan.count;
        emitted = 0;
        done = limit == 0;
        dtDay = dayNumber(start.date);

        // Occurrences share DTSTART's time of day, so UNTIL reduces to the last
        // day that may still be printed.
        lastDay = int.max;
        if (plan.hasUntil)
        {
            immutable untilDay = dayNumber(plan.until.date);
            lastDay = plan.until.secondsOfDay >= start.secondsOfDay ? untilDay : untilDay - 1;
        }

        final switch (plan.freq)
        {
        case Freq.yearly:
            yearly(sink, start.date);
            break;
        case Freq.monthly:
            monthly(sink, start.date);
            break;
        case Freq.weekly:
            weekly(sink);
            break;
        case Freq.daily:
            daily(sink);
            break;
        }
        return emitted;
    }

private:

    static void applyDefaults(ref Rule r, CivilDate d)
    {
        if (r.hasMonthDay || r.hasYearDay || r.hasWeekNo || r.hasByDay)
            return;
        final switch (r.freq)
        {
        case Freq.yearly:
            if (!r.hasMonth)
            {
                r.month[d.month] = true;
                r.hasMonth = true;
            }
            r.monthDay[d.day] = true;
            r.hasMonthDay = true;
            break;
        case Freq.monthly:
            r.monthDay[d.day] = true;
            r.hasMonthDay = true;
            break;
        case Freq.weekly:
            r.weekday[weekdayOf(dayNumber(d))] = true;
            r.hasWeekdays = true;
            break;
        case Freq.daily:
            break;
        }
    }

    void yearly(Sink)(ref Sink sink, CivilDate start)
    {
        for (int k = 0; !done; ++k)
        {
            immutable year = start.year + k * plan.interval;
            if (year > lastYear)
                break;
            immutable jan1 = firstDayOfYear(year);
            if (jan1 > lastDay)
                break;
            if (plan.hasWeekNo)
                prepareWeekNumbers(year);
            uint n = 0;
            if (plan.hasMonth)
            {
                foreach (m; 1 .. 13)
                {
                    if (!plan.month[m])
                        continue;
                    immutable before = daysBeforeMonth(year, m);
                    n = walk(jan1 + before, year, m, 1, before, daysInMonth(year, m), n);
                }
            }
            else
                n = walk(jan1, year, 1, 1, 0, yearLength(year), n);
            emitPeriod(sink, n);
        }
    }

    void monthly(Sink)(ref Sink sink, CivilDate start)
    {
        immutable base = start.year * 12 + start.month - 1;
        for (int k = 0; !done; ++k)
        {
            immutable index = base + k * plan.interval;
            immutable year = index / 12;
            if (year > lastYear)
                break;
            immutable month = index % 12 + 1;
            immutable before = daysBeforeMonth(year, month);
            immutable first = firstDayOfYear(year) + before;
            if (first > lastDay)
                break;
            if (plan.hasMonth && !plan.month[month])
                continue;
            immutable n = walk(first, year, month, 1, before, daysInMonth(year, month), 0);
            emitPeriod(sink, n);
        }
    }

    void weekly(Sink)(ref Sink sink)
    {
        immutable endDay = firstDayOfYear(lastYear + 1);
        immutable back = (weekdayOf(dtDay) - plan.weekStart + 7) % 7;
        immutable anchor = dtDay - back;
        for (int k = 0; !done; ++k)
        {
            immutable first = k == 0 ? dtDay : anchor + 7 * k * plan.interval;
            if (first >= endDay || first > lastDay)
                break;
            immutable len = k == 0 ? 7 - back : 7;
            immutable n = walkFromDay(first, len);
            emitPeriod(sink, n);
        }
    }

    void daily(Sink)(ref Sink sink)
    {
        immutable endDay = firstDayOfYear(lastYear + 1);
        for (int k = 0; !done; ++k)
        {
            immutable first = dtDay + k * plan.interval;
            if (first >= endDay || first > lastDay)
                break;
            immutable n = walkFromDay(first, 1);
            emitPeriod(sink, n);
        }
    }

    uint walkFromDay(int first, int len)
    {
        immutable date = civilFromDayNumber(first);
        immutable before = daysBeforeMonth(date.year, date.month);
        return walk(first, date.year, date.month, date.day, before + date.day - 1, len, 0);
    }

    /// Computes `s(Y)`, `weeks(Y)` and the week number given to the first days
    /// of January (SPEC step 4) for `year`.
    void prepareWeekNumbers(int year)
    {
        int s, weeks;
        weekInfo(year, s, weeks);
        weekStart0 = s;
        weekCount = weeks;
        int p;
        int sPrev, weeksPrev;
        weekInfo(year - 1, sPrev, weeksPrev);
        if (sPrev < 0)
            p = weeksPrev;
        else
            p = 52 + ((yearLength(year) - s) % 7 >= 4 ? 1 : 0);
        beforeWeekOne = plan.weekNoNeg[1] || plan.weekNo[p];
    }

    void weekInfo(int year, out int s, out int weeks) const
    {
        immutable first = (plan.weekStart - weekdayOf(firstDayOfYear(year)) + 7) % 7;
        s = first < 4 ? first : first - 7;
        immutable len = yearLength(year) - s;
        weeks = len / 7 + (len % 7 >= 4 ? 1 : 0);
    }

    /// Marks, within the `len`-day range starting on weekday `startWeekday`,
    /// the days designated by the ordinal `BYDAY` codes.
    void markOrdinalDays(int len, int startWeekday)
    {
        ordinalMask[0 .. len] = false;
        immutable lastWeekday = (startWeekday + len - 1) % 7;
        foreach (code; plan.ordinalDays)
        {
            int offset;
            if (code.ordinal > 0)
                offset = (code.weekday - startWeekday + 7) % 7 + 7 * (code.ordinal - 1);
            else
                offset = len - 1 - ((lastWeekday - code.weekday + 7) % 7 + 7 * (-code.ordinal - 1));
            if (offset >= 0 && offset < len)
                ordinalMask[offset] = true;
        }
    }

    /**
     * Walks `len` consecutive candidate days starting at day number
     * `startDay` (civil fields `year`, `month`, `dom`, 0-based day of year
     * `yday`), appending the days that pass every filter to `kept[n ..]`.
     * Returns the new number of kept days.
     */
    uint walk(int startDay, int year, int month, int dom, int yday, int len, uint n)
    {
        immutable hasMonth = plan.hasMonth;
        immutable hasMonthDay = plan.hasMonthDay;
        immutable hasYearDay = plan.hasYearDay;
        immutable hasWeekNo = plan.hasWeekNo;
        immutable hasOrdinal = plan.ordinalDays.length != 0;
        immutable hasWeekdays = plan.hasWeekdays;
        int weekday = weekdayOf(startDay);
        int monthLen = daysInMonth(year, month);
        int yearLen = yearLength(year);
        if (hasOrdinal)
            markOrdinalDays(len, weekday);

        foreach (off; 0 .. len)
        {
            bool keep = true;
            if (hasMonth && !plan.month[month])
                keep = false;
            else if (hasMonthDay && !(plan.monthDay[dom] || plan.monthDayNeg[monthLen + 1 - dom]))
                keep = false;
            else if (hasYearDay && !(plan.yearDay[yday + 1] || plan.yearDayNeg[yearLen - yday]))
                keep = false;
            else if (hasWeekNo && !weekMatches(yday))
                keep = false;
            else if (hasWeekdays && !plan.weekday[weekday])
                keep = false;
            else if (hasOrdinal && !ordinalMask[off])
                keep = false;
            if (keep)
                kept[n++] = startDay + off;

            // Advance the calendar cursor by one day.
            if (++weekday == 7)
                weekday = 0;
            ++yday;
            if (++dom > monthLen)
            {
                dom = 1;
                if (++month > 12)
                {
                    month = 1;
                    ++year;
                    yday = 0;
                    yearLen = yearLength(year);
                }
                monthLen = daysInMonth(year, month);
            }
        }
        return n;
    }

    bool weekMatches(int yday) const
    {
        if (yday < weekStart0)
            return beforeWeekOne;
        immutable w = (yday - weekStart0) / 7 + 1;
        if (w <= weekCount)
            return plan.weekNo[w] || plan.weekNoNeg[weekCount + 1 - w];
        return plan.weekNo[1];
    }

    /// Applies `BYSETPOS` (if any) to `kept[0 .. n]` and emits the result.
    void emitPeriod(Sink)(ref Sink sink, uint n)
    {
        if (n == 0)
            return;
        if (plan.setPos.length == 0)
        {
            foreach (i; 0 .. n)
            {
                if (done)
                    return;
                emitOne(sink, kept[i]);
            }
            return;
        }
        foreach (p; plan.setPos)
        {
            immutable idx = p > 0 ? p - 1 : cast(int) n + p;
            if (idx >= 0 && idx < n)
                selected[idx] = true;
        }
        foreach (i; 0 .. n)
        {
            if (!selected[i])
                continue;
            selected[i] = false;
            if (!done)
                emitOne(sink, kept[i]);
        }
    }

    void emitOne(Sink)(ref Sink sink, int day)
    {
        if (day > lastDay)
        {
            done = true;
            return;
        }
        if (day < dtDay)
            return;
        sink.put(day);
        if (++emitted >= limit)
            done = true;
    }
}

/// A sink that collects occurrence day numbers.
struct DayNumberCollector
{
    /// Collected day numbers, in order.
    int[] days;

    /// Receives one occurrence.
    void put(int dayNumber)
    {
        days ~= dayNumber;
    }
}

/**
 * Convenience wrapper: the first `limit` occurrences of `rule` starting at
 * `start`, as date-times.
 */
LocalDateTime[] occurrences(Rule rule, LocalDateTime start, size_t limit)
{
    Expander ex;
    DayNumberCollector sink;
    ex.expand(rule, start, limit, sink);
    auto result = new LocalDateTime[sink.days.length];
    foreach (i, d; sink.days)
    {
        result[i] = start;
        result[i].date = civilFromDayNumber(d);
    }
    return result;
}
