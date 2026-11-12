/**
 * Recurrence rule expansion (an RFC 5545 `RRULE` subset) with python-dateutil
 * semantics, using only integer calendar arithmetic implemented in this package.
 *
 * ---
 * import rrule;
 *
 * auto start = LocalDateTime.parse("19970902T090000");
 * auto rule = parseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3");
 * foreach (t; expand(start, rule))
 *     writeln(t); // 19970926T090000, 19971031T090000, 19971128T090000
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `rrule.calendar` — day numbers, leap years, weekdays)
 *   $(LI `rrule.datetime` — `LocalDateTime` and its text form)
 *   $(LI `rrule.rule` — the `Rule` type and `parseRule`)
 *   $(LI `rrule.weekno` — `BYWEEKNO` week numbering)
 *   $(LI `rrule.expand` — `Occurrences` range and `expand`)
 *   $(LI `rrule.query` — the `<DTSTART> <RRULE> <N>` line format)
 * )
 */
module rrule;

public import rrule.calendar;
public import rrule.datetime;
public import rrule.expand;
public import rrule.query;
public import rrule.rule;
public import rrule.weekno;
