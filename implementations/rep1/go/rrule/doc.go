// Package rrule expands iCalendar (RFC 5545) recurrence rules into lists of
// occurrences, following the semantics of python-dateutil's rrule for the
// supported subset: FREQ of YEARLY, MONTHLY, WEEKLY or DAILY with the
// INTERVAL, COUNT, UNTIL, WKST, BYMONTH, BYMONTHDAY, BYYEARDAY, BYWEEKNO,
// BYDAY and BYSETPOS parts.
//
// All times are floating local times; there are no time zones. The calendar
// arithmetic (leap years, weekdays, week numbers) is implemented by the
// package itself on plain integer day numbers.
//
// A typical use parses a rule and expands it from a start time:
//
//	r, err := rrule.ParseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")
//	if err != nil { ... }
//	start, _ := rrule.ParseDateTime("19970902T090000")
//	times := r.Expand(start, 100)
//
// For bulk work, reuse an [Expander], which keeps its scratch buffers between
// calls and can append the textual form of the occurrences directly.
package rrule
