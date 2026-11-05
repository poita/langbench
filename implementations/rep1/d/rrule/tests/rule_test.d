/// Unit tests for `rrule.rule` parsing.
module rule_test;

import rrule.errors;
import rrule.rule;

import std.exception : assertThrown;

unittest // simple parts
{
    auto r = parseRule("FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH");
    assert(r.freq == Freq.weekly);
    assert(r.interval == 2);
    assert(r.hasCount && r.count == 8);
    assert(r.weekStart == 6);
    assert(r.hasWeekdays && r.weekday[1] && r.weekday[3] && !r.weekday[0]);
    assert(r.ordinalDays.length == 0);
    assert(r.hasByDay);
}

unittest // list tables
{
    auto r = parseRule("FREQ=YEARLY;BYMONTH=1,12;BYMONTHDAY=1,-1;BYYEARDAY=100,-366;BYWEEKNO=53,-1;BYSETPOS=-1,2");
    assert(r.hasMonth && r.month[1] && r.month[12] && !r.month[6]);
    assert(r.monthDay[1] && r.monthDayNeg[1] && !r.monthDay[2]);
    assert(r.yearDay[100] && r.yearDayNeg[366]);
    assert(r.weekNo[53] && r.weekNoNeg[1]);
    assert(r.setPos == [-1, 2]);
}

unittest // ordinal BYDAY and UNTIL
{
    auto r = parseRule("UNTIL=20240430T000000;FREQ=MONTHLY;BYDAY=-1FR,2MO");
    assert(r.hasUntil && r.until.date.month == 4);
    assert(r.ordinalDays == [OrdinalDay(-1, 4), OrdinalDay(2, 0)]);
    assert(!r.hasWeekdays);
}

unittest // reuse clears previous state
{
    Rule r;
    parseRuleInto(r, "FREQ=MONTHLY;BYDAY=2MO;BYSETPOS=1;COUNT=3");
    parseRuleInto(r, "FREQ=DAILY");
    assert(r.freq == Freq.daily && !r.hasCount && !r.hasByDay && r.setPos.length == 0);
    assert(r.interval == 1 && r.weekStart == 0);
}

unittest // malformed rules
{
    assertThrown!RRuleException(parseRule("INTERVAL=2"));
    assertThrown!RRuleException(parseRule("FREQ=HOURLY"));
    assertThrown!RRuleException(parseRule("FREQ=DAILY;BYMONTH=13"));
    assertThrown!RRuleException(parseRule("FREQ=DAILY;BYFOO=1"));
    assertThrown!RRuleException(parseRule("FREQ=DAILY;INTERVAL=0"));
    assertThrown!RRuleException(parseRule("FREQ=DAILY;BYDAY=XX"));
    assertThrown!RRuleException(parseRule("FREQ=DAILY;"));
    assertThrown!RRuleException(parseRule("FREQ"));
}
