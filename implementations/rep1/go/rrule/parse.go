package rrule

import (
	"errors"
	"fmt"
	"strings"
)

// ErrInvalidRule is wrapped by every error returned from [ParseRule] and
// [Rule.Validate].
var ErrInvalidRule = errors.New("rrule: invalid rule")

func ruleErr(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidRule, fmt.Sprintf(format, args...))
}

// ParseRule parses the value of an RRULE property, for example
// "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=8". Part names and values must
// be upper case; each part may appear at most once.
func ParseRule(s string) (*Rule, error) {
	r := &Rule{}
	var seen uint16
	for len(s) > 0 {
		var part string
		if i := strings.IndexByte(s, ';'); i >= 0 {
			part, s = s[:i], s[i+1:]
		} else {
			part, s = s, ""
		}
		eq := strings.IndexByte(part, '=')
		if eq < 0 {
			return nil, ruleErr("part %q has no '='", part)
		}
		name, val := part[:eq], part[eq+1:]
		idx := partIndex(name)
		if idx < 0 {
			return nil, ruleErr("unknown part %q", name)
		}
		if seen&(1<<idx) != 0 {
			return nil, ruleErr("duplicate part %q", name)
		}
		seen |= 1 << idx
		if err := r.setPart(name, val); err != nil {
			return nil, err
		}
	}
	if err := r.Validate(); err != nil {
		return nil, err
	}
	return r, nil
}

var partNames = []string{"FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST",
	"BYMONTH", "BYMONTHDAY", "BYYEARDAY", "BYWEEKNO", "BYDAY", "BYSETPOS"}

func partIndex(name string) int {
	for i, n := range partNames {
		if n == name {
			return i
		}
	}
	return -1
}

func (r *Rule) setPart(name, val string) (err error) {
	switch name {
	case "FREQ":
		switch val {
		case "YEARLY":
			r.Freq = Yearly
		case "MONTHLY":
			r.Freq = Monthly
		case "WEEKLY":
			r.Freq = Weekly
		case "DAILY":
			r.Freq = Daily
		default:
			return ruleErr("unsupported FREQ %q", val)
		}
	case "INTERVAL":
		r.Interval, err = parseInt(name, val)
	case "COUNT":
		r.Count, err = parseInt(name, val)
	case "UNTIL":
		var dt DateTime
		if dt, err = ParseDateTime(val); err != nil {
			return ruleErr("bad UNTIL %q", val)
		}
		r.Until = &dt
	case "WKST":
		r.WeekStart, err = parseWeekday(val)
	case "BYMONTH":
		r.ByMonth, err = parseIntList(name, val)
	case "BYMONTHDAY":
		r.ByMonthDay, err = parseIntList(name, val)
	case "BYYEARDAY":
		r.ByYearDay, err = parseIntList(name, val)
	case "BYWEEKNO":
		r.ByWeekNo, err = parseIntList(name, val)
	case "BYSETPOS":
		r.BySetPos, err = parseIntList(name, val)
	case "BYDAY":
		r.ByDay, err = parseByDay(val)
	}
	return err
}

func parseInt(name, s string) (int, error) {
	i := 0
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i++
	}
	if i == len(s) || len(s)-i > 9 {
		return 0, ruleErr("bad integer %q in %s", s, name)
	}
	v := 0
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, ruleErr("bad integer %q in %s", s, name)
		}
		v = v*10 + int(c-'0')
	}
	if neg {
		v = -v
	}
	return v, nil
}

func parseIntList(name, s string) ([]int, error) {
	out := make([]int, 0, strings.Count(s, ",")+1)
	for {
		item := s
		i := strings.IndexByte(s, ',')
		if i >= 0 {
			item = s[:i]
		}
		v, err := parseInt(name, item)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
		if i < 0 {
			return out, nil
		}
		s = s[i+1:]
	}
}

func parseWeekday(s string) (Weekday, error) {
	for i, c := range weekdayCodes {
		if c == s {
			return Weekday(i), nil
		}
	}
	return 0, ruleErr("bad weekday %q", s)
}

func parseByDay(s string) ([]WeekdayNum, error) {
	var out []WeekdayNum
	for _, item := range strings.Split(s, ",") {
		if len(item) < 2 {
			return nil, ruleErr("bad BYDAY entry %q", item)
		}
		wd, err := parseWeekday(item[len(item)-2:])
		if err != nil {
			return nil, err
		}
		n := 0
		if pre := item[:len(item)-2]; pre != "" {
			if n, err = parseInt("BYDAY", pre); err != nil {
				return nil, err
			}
			if n == 0 {
				return nil, ruleErr("BYDAY ordinal 0 in %q", item)
			}
		}
		out = append(out, WeekdayNum{n, wd})
	}
	return out, nil
}

// Validate checks that the rule is well formed: a known frequency, values
// within their documented ranges, and only combinations of parts that the
// package supports. [ParseRule] calls it; call it yourself on rules built
// by hand.
func (r *Rule) Validate() error {
	if r.Freq < Yearly || r.Freq > Daily {
		return ruleErr("FREQ is required")
	}
	if r.Interval < 0 || r.Interval > 100 {
		return ruleErr("INTERVAL %d out of range 1-100", r.Interval)
	}
	if r.Count < 0 || r.Count > 100000 {
		return ruleErr("COUNT %d out of range 1-100000", r.Count)
	}
	if r.Count > 0 && r.Until != nil {
		return ruleErr("COUNT and UNTIL are mutually exclusive")
	}
	if r.Until != nil && !r.Until.Valid() {
		return ruleErr("UNTIL is not a valid date-time")
	}
	if r.WeekStart < Monday || r.WeekStart > Sunday {
		return ruleErr("bad WKST")
	}
	check := func(name string, vals []int, max int) error {
		for _, v := range vals {
			if v == 0 || v > max || v < -max {
				return ruleErr("%s value %d out of range", name, v)
			}
		}
		return nil
	}
	for _, m := range r.ByMonth {
		if m < 1 || m > 12 {
			return ruleErr("BYMONTH value %d out of range", m)
		}
	}
	if err := check("BYMONTHDAY", r.ByMonthDay, 31); err != nil {
		return err
	}
	if err := check("BYYEARDAY", r.ByYearDay, 366); err != nil {
		return err
	}
	if err := check("BYWEEKNO", r.ByWeekNo, 53); err != nil {
		return err
	}
	if err := check("BYSETPOS", r.BySetPos, 366); err != nil {
		return err
	}
	if (len(r.ByYearDay) > 0 || len(r.ByWeekNo) > 0) && r.Freq != Yearly {
		return ruleErr("BYYEARDAY and BYWEEKNO require FREQ=YEARLY")
	}
	ordinals := 0
	for _, d := range r.ByDay {
		if d.Weekday < Monday || d.Weekday > Sunday {
			return ruleErr("bad BYDAY weekday")
		}
		if d.Ordinal != 0 {
			ordinals++
			limit := 5
			if r.Freq == Yearly && len(r.ByMonth) == 0 {
				limit = 53
			}
			if d.Ordinal > limit || d.Ordinal < -limit {
				return ruleErr("BYDAY ordinal %d out of range", d.Ordinal)
			}
		}
	}
	if ordinals > 0 {
		if ordinals != len(r.ByDay) {
			return ruleErr("BYDAY mixes plain and ordinal entries")
		}
		if r.Freq != Monthly && r.Freq != Yearly {
			return ruleErr("BYDAY ordinals require FREQ=MONTHLY or YEARLY")
		}
		if len(r.ByWeekNo) > 0 {
			return ruleErr("BYDAY ordinals cannot be combined with BYWEEKNO")
		}
	}
	return nil
}
