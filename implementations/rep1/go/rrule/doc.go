// Package rrule expands RFC 5545 recurrence rules (RRULE) into lists of
// occurrences.
//
// It supports FREQ=YEARLY, MONTHLY, WEEKLY and DAILY with INTERVAL, COUNT,
// UNTIL, WKST, BYMONTH, BYMONTHDAY, BYYEARDAY, BYWEEKNO, BYDAY (with ordinals)
// and BYSETPOS, following the behaviour of python-dateutil's rrule. All times
// are floating local times; there are no time zones.
//
// Calendar arithmetic is done in this package on integer day numbers, so it
// does not depend on the standard library's time package.
//
// Typical use:
//
//	rule, err := rrule.ParseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")
//	start, _ := rrule.ParseDateTime("19970902T090000")
//	times, err := rule.Expand(start, 0)
//
// The package is split by responsibility: calendar.go (date arithmetic),
// datetime.go (DateTime and Weekday), rule.go and parse.go (the Rule type and
// its text form), weekno.go (BYWEEKNO numbering) and expand.go (expansion).
package rrule
