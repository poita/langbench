package rrule

import (
	"errors"
	"fmt"
)

// DateTime is a floating local date and time (no time zone).
type DateTime struct {
	Year, Month, Day     int
	Hour, Minute, Second int
}

// ErrInvalidDateTime is returned for malformed or out-of-range date-times.
var ErrInvalidDateTime = errors.New("rrule: invalid date-time")

// Valid reports whether dt is a real calendar date-time with a year in
// 1000–9999.
func (dt DateTime) Valid() bool {
	return dt.Year >= 1000 && dt.Year <= maxYear &&
		dt.Month >= 1 && dt.Month <= 12 &&
		dt.Day >= 1 && dt.Day <= DaysInMonth(dt.Year, dt.Month) &&
		dt.Hour >= 0 && dt.Hour <= 23 &&
		dt.Minute >= 0 && dt.Minute <= 59 &&
		dt.Second >= 0 && dt.Second <= 59
}

// Weekday returns the day of the week of dt.
func (dt DateTime) Weekday() Weekday { return DayOfWeek(dt.Year, dt.Month, dt.Day) }

// Compare returns -1, 0 or +1 as dt is before, equal to or after other.
func (dt DateTime) Compare(other DateTime) int {
	a, b := dt.key(), other.key()
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// key is a single integer that orders date-times chronologically.
func (dt DateTime) key() int {
	return dayNumber(dt.Year, dt.Month, dt.Day)*86400 + dt.secondsOfDay()
}

func (dt DateTime) secondsOfDay() int {
	return dt.Hour*3600 + dt.Minute*60 + dt.Second
}

// String formats dt as YYYYMMDDTHHMMSS.
func (dt DateTime) String() string {
	return string(appendStamp(make([]byte, 0, 15), dt.Year, dt.Month, dt.Day, dt.secondsOfDay()))
}

// ParseDateTime parses the form YYYYMMDDTHHMMSS.
func ParseDateTime(s string) (DateTime, error) {
	if len(s) != 15 || s[8] != 'T' {
		return DateTime{}, fmt.Errorf("%w: %q", ErrInvalidDateTime, s)
	}
	f := func(i, n int) int {
		v := 0
		for _, c := range []byte(s[i : i+n]) {
			if c < '0' || c > '9' {
				return -1
			}
			v = v*10 + int(c-'0')
		}
		return v
	}
	dt := DateTime{f(0, 4), f(4, 2), f(6, 2), f(9, 2), f(11, 2), f(13, 2)}
	if dt.Year < 0 || dt.Month < 0 || dt.Day < 0 || dt.Hour < 0 || dt.Minute < 0 || dt.Second < 0 || !dt.Valid() {
		return DateTime{}, fmt.Errorf("%w: %q", ErrInvalidDateTime, s)
	}
	return dt, nil
}

// appendStamp appends "YYYYMMDDTHHMMSS" for the given date and seconds of day.
func appendStamp(dst []byte, y, m, d, sec int) []byte {
	h := sec / 3600
	mi := sec / 60 % 60
	s := sec % 60
	return append(dst,
		byte('0'+y/1000), byte('0'+y/100%10), byte('0'+y/10%10), byte('0'+y%10),
		byte('0'+m/10), byte('0'+m%10),
		byte('0'+d/10), byte('0'+d%10),
		'T',
		byte('0'+h/10), byte('0'+h%10),
		byte('0'+mi/10), byte('0'+mi%10),
		byte('0'+s/10), byte('0'+s%10))
}
