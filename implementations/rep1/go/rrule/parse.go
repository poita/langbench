package rrule

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseRule parses an RFC 5545 RRULE value such as
// "FREQ=MONTHLY;BYDAY=-1FR;COUNT=10" and validates it.
func ParseRule(s string) (Rule, error) {
	r := Rule{Interval: 1, WeekStart: Monday}
	seen := map[string]bool{}
	haveFreq := false
	for _, part := range strings.Split(s, ";") {
		name, value, ok := strings.Cut(part, "=")
		if !ok || value == "" {
			return Rule{}, fmt.Errorf("rrule: malformed rule part %q", part)
		}
		if seen[name] {
			return Rule{}, fmt.Errorf("rrule: duplicate %s", name)
		}
		seen[name] = true
		var err error
		switch name {
		case "FREQ":
			haveFreq = true
			found := false
			for i, n := range freqNames {
				if n == value {
					r.Freq, found = Frequency(i), true
				}
			}
			if !found {
				err = fmt.Errorf("rrule: unsupported FREQ %q", value)
			}
		case "INTERVAL":
			r.Interval, err = strconv.Atoi(value)
		case "COUNT":
			r.Count, err = strconv.Atoi(value)
			if err == nil && r.Count < 1 {
				err = fmt.Errorf("rrule: COUNT must be positive")
			}
		case "UNTIL":
			r.Until, err = ParseDateTime(value)
			r.HasUntil = err == nil
		case "WKST":
			w, ok := parseWeekday(value)
			if !ok {
				err = fmt.Errorf("rrule: invalid WKST %q", value)
			}
			r.WeekStart = w
		case "BYMONTH":
			r.ByMonth, err = parseInts(value)
		case "BYMONTHDAY":
			r.ByMonthDay, err = parseInts(value)
		case "BYYEARDAY":
			r.ByYearDay, err = parseInts(value)
		case "BYWEEKNO":
			r.ByWeekNo, err = parseInts(value)
		case "BYSETPOS":
			r.BySetPos, err = parseInts(value)
		case "BYDAY":
			r.ByDay, err = parseByDay(value)
		default:
			err = fmt.Errorf("rrule: unsupported part %q", name)
		}
		if err != nil {
			return Rule{}, err
		}
	}
	if !haveFreq {
		return Rule{}, fmt.Errorf("rrule: missing FREQ")
	}
	if err := r.Validate(); err != nil {
		return Rule{}, err
	}
	return r, nil
}

func parseInts(s string) ([]int, error) {
	fields := strings.Split(s, ",")
	out := make([]int, 0, len(fields))
	for _, f := range fields {
		v, err := strconv.Atoi(f)
		if err != nil {
			return nil, fmt.Errorf("rrule: invalid integer %q", f)
		}
		out = append(out, v)
	}
	return out, nil
}

func parseByDay(s string) ([]WeekdaySpec, error) {
	fields := strings.Split(s, ",")
	out := make([]WeekdaySpec, 0, len(fields))
	for _, f := range fields {
		if len(f) < 2 {
			return nil, fmt.Errorf("rrule: invalid BYDAY entry %q", f)
		}
		day, ok := parseWeekday(f[len(f)-2:])
		if !ok {
			return nil, fmt.Errorf("rrule: invalid BYDAY entry %q", f)
		}
		spec := WeekdaySpec{Day: day}
		if ord := f[:len(f)-2]; ord != "" {
			n, err := strconv.Atoi(ord)
			if err != nil || n == 0 {
				return nil, fmt.Errorf("rrule: invalid BYDAY ordinal in %q", f)
			}
			spec.N = n
		}
		out = append(out, spec)
	}
	return out, nil
}
