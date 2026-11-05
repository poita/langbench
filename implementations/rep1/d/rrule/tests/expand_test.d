/// Unit tests for `rrule.expand`, using the examples of the specification.
module expand_test;

import rrule.calendar;
import rrule.expand;
import rrule.rule;
import rrule.timestamp;

import std.array : join;
import std.algorithm : map;

/// Expands `rule` from `start` and returns the stamps joined by spaces.
private string run(string start, string rule, size_t n)
{
    auto occ = occurrences(parseRule(rule), parseTimestamp(start), n);
    return occ.map!(formatTimestamp).join(" ");
}

unittest // last Friday of every second month
{
    assert(run("19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10", 100)
        == "19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 "
         ~ "19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000");
}

unittest // WKST changes the week grid
{
    assert(run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8", 100)
        == "19970902T090000 19970904T090000 19970916T090000 19970918T090000 "
         ~ "19970930T090000 19971002T090000 19971014T090000 19971016T090000");
    assert(run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4)
        == "19970902T090000 19970907T090000 19970916T090000 19970921T090000");
}

unittest // defaults derived from DTSTART
{
    assert(run("20240229T120000", "FREQ=YEARLY;COUNT=3", 10)
        == "20240229T120000 20280229T120000 20320229T120000");
    // The 31st only exists in some months.
    assert(run("20240131T000000", "FREQ=MONTHLY;COUNT=4", 10)
        == "20240131T000000 20240331T000000 20240531T000000 20240731T000000");
    // WEEKLY defaults to DTSTART's weekday (a Tuesday).
    assert(run("19970902T090000", "FREQ=WEEKLY;COUNT=3", 10)
        == "19970902T090000 19970909T090000 19970916T090000");
}

unittest // negative month days and UNTIL (inclusive)
{
    assert(run("20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000", 10)
        == "20240131T000000 20240229T000000 20240331T000000 20240430T000000");
    // UNTIL before DTSTART gives no occurrences.
    assert(run("20240131T000000", "FREQ=DAILY;UNTIL=20240130T000000", 10) == "");
}

unittest // BYSETPOS
{
    assert(run("20240301T080000", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", 10)
        == "20240329T080000 20240430T080000 20240531T080000");
    // The selected day before DTSTART is discarded without counting.
    assert(run("20240320T080000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2", 10)
        == "20240401T080000 20240506T080000");
    // BYSETPOS alone acts on the defaults.
    assert(run("20240315T000000", "FREQ=MONTHLY;BYSETPOS=2;COUNT=2", 10) == "");
    assert(run("20240315T000000", "FREQ=MONTHLY;BYSETPOS=1;COUNT=2", 10)
        == "20240315T000000 20240415T000000");
    // Duplicate selections collapse.
    assert(run("20240101T000000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1,-5,1;COUNT=1", 10)
        == "20240101T000000");
}

unittest // impossible dates run to the year-9999 limit and yield nothing
{
    assert(run("20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5", 10) == "");
}

unittest // BYWEEKNO, including the special January week number
{
    assert(run("20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3", 10)
        == "20201228T000000 20261228T000000 20321227T000000");
    assert(run("20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4", 10)
        == "20110101T000000 20110102T000000 20151228T000000 20151229T000000");
}

unittest // ordinals within months and within the year
{
    assert(run("20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4", 10)
        == "20240108T000000 20240708T000000 20250113T000000 20250714T000000");
    assert(run("20240101T000000", "FREQ=YEARLY;BYDAY=20MO;COUNT=2", 10)
        == "20240513T000000 20250519T000000");
    assert(run("20240101T000000", "FREQ=YEARLY;BYDAY=-1MO;COUNT=1", 10) == "20241230T000000");
    // A fifth Monday that does not exist contributes nothing.
    assert(run("20240201T000000", "FREQ=MONTHLY;BYDAY=5MO;COUNT=2", 10)
        == "20240429T000000 20240729T000000");
}

unittest // limit N and COUNT interplay
{
    assert(run("20240101T000000", "FREQ=DAILY;COUNT=10", 3)
        == "20240101T000000 20240102T000000 20240103T000000");
    assert(run("20240101T000000", "FREQ=DAILY;COUNT=2", 100)
        == "20240101T000000 20240102T000000");
}

unittest // BYYEARDAY with negative values, INTERVAL, month filter
{
    assert(run("20240101T000000", "FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=4", 10)
        == "20240101T000000 20241231T000000 20250101T000000 20251231T000000");
    assert(run("20240101T000000", "FREQ=DAILY;INTERVAL=10;BYMONTH=2;COUNT=3", 10)
        == "20240210T000000 20240220T000000 20250204T000000");
}

unittest // the year-9999 limit
{
    assert(run("99991230T010203", "FREQ=DAILY", 10) == "99991230T010203 99991231T010203");
    assert(run("99991201T000000", "FREQ=MONTHLY;INTERVAL=2", 10) == "99991201T000000");
}

unittest // an Expander can be reused across rules
{
    Expander ex;
    DayNumberCollector a, b;
    auto start = parseTimestamp("20240101T000000");
    assert(ex.expand(parseRule("FREQ=DAILY"), start, 5, a) == 5);
    assert(ex.expand(parseRule("FREQ=WEEKLY;BYDAY=FR"), start, 3, b) == 3);
    assert(a.days[0] == dayNumber(2024, 1, 1) && a.days[4] == dayNumber(2024, 1, 5));
    assert(b.days == [dayNumber(2024, 1, 5), dayNumber(2024, 1, 12), dayNumber(2024, 1, 19)]);
}
