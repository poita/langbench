/**
 * rrule — recurrence rule (RFC 5545 `RRULE` subset) expansion.
 *
 * Public modules:
 * $(UL
 *   $(LI `rrule.calendar`  – day numbers, leap years, weekdays, civil dates)
 *   $(LI `rrule.timestamp` – `YYYYMMDDTHHMMSS` parsing and formatting)
 *   $(LI `rrule.rule`      – the `Rule` record and `parseRule`)
 *   $(LI `rrule.expand`    – the `Expander` and `occurrences`)
 *   $(LI `rrule.batch`     – line-oriented batch processing used by the CLI)
 *   $(LI `rrule.errors`    – `RRuleException`)
 * )
 */
module rrule;

public import rrule.batch;
public import rrule.calendar;
public import rrule.errors;
public import rrule.expand;
public import rrule.rule;
public import rrule.timestamp;
