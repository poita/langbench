package rrule

import (
	"fmt"
)

// DateTime is a floating (zone-less) calendar date and time of day in the
// proleptic Gregorian calendar.
type DateTime struct {
	Year, Month, Day     int
	Hour, Minute, Second int
}

// Weekday returns the day of the week of the date.
func (t DateTime) Weekday() Weekday {
	return Weekday(weekdayOf(daysFromCivil(t.Year, t.Month, t.Day)))
}

// Before reports whether t is chronologically before u.
func (t DateTime) Before(u DateTime) bool { return t.ordinal() < u.ordinal() }

// ordinal returns seconds since 0001-01-01T00:00:00, a total order on
// date-times.
func (t DateTime) ordinal() int64 {
	return int64(daysFromCivil(t.Year, t.Month, t.Day))*secondsPerDay + int64(t.timeOfDay())
}

func (t DateTime) timeOfDay() int {
	return t.Hour*3600 + t.Minute*60 + t.Second
}

// Valid reports whether every field is in range and the date exists.
func (t DateTime) Valid() bool {
	return t.Year >= 1 && t.Year <= 9999 &&
		t.Month >= 1 && t.Month <= 12 &&
		t.Day >= 1 && t.Day <= DaysInMonth(t.Year, t.Month) &&
		t.Hour >= 0 && t.Hour <= 23 &&
		t.Minute >= 0 && t.Minute <= 59 &&
		t.Second >= 0 && t.Second <= 59
}

// String formats t as YYYYMMDDTHHMMSS.
func (t DateTime) String() string {
	return string(t.AppendFormat(nil))
}

// AppendFormat appends the YYYYMMDDTHHMMSS form of t to b.
func (t DateTime) AppendFormat(b []byte) []byte {
	return appendFormat(b, t.Year, t.Month, t.Day, t.timeOfDay())
}

func appendFormat(b []byte, y, m, d, tod int) []byte {
	return append(b,
		byte('0'+y/1000%10), byte('0'+y/100%10), byte('0'+y/10%10), byte('0'+y%10),
		byte('0'+m/10), byte('0'+m%10),
		byte('0'+d/10), byte('0'+d%10),
		'T',
		byte('0'+tod/36000), byte('0'+tod/3600%10),
		byte('0'+tod/600%6), byte('0'+tod/60%10),
		byte('0'+tod/10%6), byte('0'+tod%10),
	)
}

// ParseDateTime parses the YYYYMMDDTHHMMSS form.
func ParseDateTime(s string) (DateTime, error) {
	if len(s) != 15 || s[8] != 'T' {
		return DateTime{}, fmt.Errorf("rrule: invalid date-time %q", s)
	}
	for i := 0; i < 15; i++ {
		if i != 8 && (s[i] < '0' || s[i] > '9') {
			return DateTime{}, fmt.Errorf("rrule: invalid date-time %q", s)
		}
	}
	num := func(a, b int) int {
		v := 0
		for _, c := range []byte(s[a:b]) {
			v = v*10 + int(c-'0')
		}
		return v
	}
	t := DateTime{num(0, 4), num(4, 6), num(6, 8), num(9, 11), num(11, 13), num(13, 15)}
	if !t.Valid() {
		return DateTime{}, fmt.Errorf("rrule: invalid date-time %q", s)
	}
	return t, nil
}

// Weekday is a day of the week, numbered Monday = 0 to Sunday = 6.
type Weekday int

// Days of the week.
const (
	Monday Weekday = iota
	Tuesday
	Wednesday
	Thursday
	Friday
	Saturday
	Sunday
)

var weekdayCodes = [7]string{"MO", "TU", "WE", "TH", "FR", "SA", "SU"}

// String returns the two-letter RFC 5545 code (MO, TU, ...).
func (w Weekday) String() string {
	if w < 0 || w > 6 {
		return fmt.Sprintf("Weekday(%d)", int(w))
	}
	return weekdayCodes[w]
}

func parseWeekday(s string) (Weekday, bool) {
	for i, c := range weekdayCodes {
		if c == s {
			return Weekday(i), true
		}
	}
	return 0, false
}
