package rrule

import (
	"errors"
	"fmt"
)

// Frequency is the base period of a recurrence rule.
type Frequency int

// Supported frequencies.
const (
	Yearly Frequency = iota
	Monthly
	Weekly
	Daily
)

var freqNames = [...]string{"YEARLY", "MONTHLY", "WEEKLY", "DAILY"}

// String returns the RFC 5545 name of the frequency.
func (f Frequency) String() string {
	if f < 0 || int(f) >= len(freqNames) {
		return fmt.Sprintf("Frequency(%d)", int(f))
	}
	return freqNames[f]
}

// WeekdaySpec is one entry of a BYDAY list. N is the optional ordinal
// (1-53 or -53 to -1); it is zero for a plain weekday code such as "MO".
type WeekdaySpec struct {
	N   int
	Day Weekday
}

// String returns the RFC 5545 form, e.g. "MO", "2MO" or "-1FR".
func (s WeekdaySpec) String() string {
	if s.N == 0 {
		return s.Day.String()
	}
	return fmt.Sprintf("%d%s", s.N, s.Day)
}

// Rule is a recurrence rule: the subset of RFC 5545 RRULE understood by this
// package. The zero value is not useful; Interval must be at least 1, which
// ParseRule guarantees.
//
// Absent BY... lists are nil. Absent COUNT is zero. UNTIL is optional and
// present only when HasUntil is true.
type Rule struct {
	Freq      Frequency
	Interval  int
	Count     int // 0 means unlimited
	HasUntil  bool
	Until     DateTime // inclusive; meaningful only if HasUntil
	WeekStart Weekday  // WKST; Monday by default

	ByMonth    []int
	ByMonthDay []int
	ByYearDay  []int
	ByWeekNo   []int
	ByDay      []WeekdaySpec
	BySetPos   []int
}

// Validate checks the rule for internal consistency: the value ranges and the
// combinations of parts that SPEC.md rules out.
func (r *Rule) Validate() error {
	if r.Freq < Yearly || r.Freq > Daily {
		return errors.New("rrule: invalid FREQ")
	}
	if r.Interval < 1 || r.Interval > 100 {
		return errors.New("rrule: INTERVAL must be 1-100")
	}
	if r.Count < 0 || r.Count > 100000 {
		return errors.New("rrule: COUNT must be 1-100000")
	}
	if r.Count != 0 && r.HasUntil {
		return errors.New("rrule: COUNT and UNTIL are mutually exclusive")
	}
	if r.HasUntil && !r.Until.Valid() {
		return errors.New("rrule: invalid UNTIL")
	}
	if r.WeekStart < Monday || r.WeekStart > Sunday {
		return errors.New("rrule: invalid WKST")
	}
	if err := checkList("BYMONTH", r.ByMonth, 1, 12, false); err != nil {
		return err
	}
	if err := checkList("BYMONTHDAY", r.ByMonthDay, 1, 31, true); err != nil {
		return err
	}
	if err := checkList("BYYEARDAY", r.ByYearDay, 1, 366, true); err != nil {
		return err
	}
	if err := checkList("BYWEEKNO", r.ByWeekNo, 1, 53, true); err != nil {
		return err
	}
	if err := checkList("BYSETPOS", r.BySetPos, 1, 366, true); err != nil {
		return err
	}
	if len(r.ByYearDay) > 0 && r.Freq != Yearly {
		return errors.New("rrule: BYYEARDAY requires FREQ=YEARLY")
	}
	if len(r.ByWeekNo) > 0 && r.Freq != Yearly {
		return errors.New("rrule: BYWEEKNO requires FREQ=YEARLY")
	}
	ordinals, plain := 0, 0
	for _, s := range r.ByDay {
		if s.Day < Monday || s.Day > Sunday {
			return errors.New("rrule: invalid BYDAY weekday")
		}
		if s.N == 0 {
			plain++
			continue
		}
		ordinals++
		limit := 53
		if r.Freq == Monthly || (r.Freq == Yearly && len(r.ByMonth) > 0) {
			limit = 5
		}
		if s.N < -limit || s.N > limit {
			return fmt.Errorf("rrule: BYDAY ordinal %d out of range", s.N)
		}
	}
	if ordinals > 0 {
		if plain > 0 {
			return errors.New("rrule: BYDAY mixes plain and ordinal entries")
		}
		if r.Freq != Monthly && r.Freq != Yearly {
			return errors.New("rrule: BYDAY ordinals require FREQ=MONTHLY or YEARLY")
		}
		if len(r.ByWeekNo) > 0 {
			return errors.New("rrule: BYDAY ordinals cannot be combined with BYWEEKNO")
		}
	}
	return nil
}

func checkList(name string, vals []int, lo, hi int, signed bool) error {
	for _, v := range vals {
		a := v
		if a < 0 {
			if !signed {
				return fmt.Errorf("rrule: %s value %d out of range", name, v)
			}
			a = -a
		}
		if a < lo || a > hi {
			return fmt.Errorf("rrule: %s value %d out of range", name, v)
		}
	}
	return nil
}
