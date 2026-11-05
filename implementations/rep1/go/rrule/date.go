package rrule

// Calendar arithmetic on the proleptic Gregorian calendar.
//
// A date is represented internally by a day number: the count of days since
// 0001-01-01, which is day 0 and a Monday. The weekday of day number n is
// therefore n mod 7 with Monday = 0.

// Weekday numbers a day of the week, Monday = 0 through Sunday = 6.
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

// String returns the two-letter RFC 5545 code ("MO" … "SU").
func (w Weekday) String() string {
	if w < 0 || w > 6 {
		return "??"
	}
	return weekdayCodes[w]
}

// daysBeforeMonth[m] is the number of days in a common year before month m
// (1-based; index 13 holds the year length).
var daysBeforeMonth = [14]int{0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365}

var monthLengths = [13]int{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

const (
	daysPer400Years = 146097
	// maxYear is the last year that is ever expanded.
	maxYear = 9999
)

// IsLeapYear reports whether y is a leap year in the Gregorian calendar.
func IsLeapYear(y int) bool {
	return y%4 == 0 && (y%100 != 0 || y%400 == 0)
}

// DaysInMonth returns the number of days in the given month (1–12) of year y.
func DaysInMonth(y, m int) int {
	if m == 2 && IsLeapYear(y) {
		return 29
	}
	return monthLengths[m]
}

// DaysInYear returns 366 for leap years and 365 otherwise.
func DaysInYear(y int) int {
	if IsLeapYear(y) {
		return 366
	}
	return 365
}

// daysBeforeYear returns the day number of 1 January of year y.
func daysBeforeYear(y int) int {
	p := y - 1
	return 365*p + p/4 - p/100 + p/400
}

// dayNumber converts a civil date to a day number.
func dayNumber(y, m, d int) int {
	n := daysBeforeYear(y) + daysBeforeMonth[m] + d - 1
	if m > 2 && IsLeapYear(y) {
		n++
	}
	return n
}

// civilFromDay converts a day number back to a civil date using the
// closed-form 400-year-era computation (no loops).
func civilFromDay(n int) (y, m, d int) {
	// Shift to days since 0000-03-01 so that leap days fall at year end.
	z := n + 306
	era := z / daysPer400Years
	doe := z - era*daysPer400Years
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y = yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = doy - (153*mp+2)/5 + 1
	if mp < 10 {
		m = mp + 3
	} else {
		m = mp - 9
	}
	if m <= 2 {
		y++
	}
	return
}

// DayOfWeek returns the weekday of the given date.
func DayOfWeek(y, m, d int) Weekday {
	return Weekday(dayNumber(y, m, d) % 7)
}

// mod7 returns n mod 7 in 0..6 for any integer n.
func mod7(n int) int {
	r := n % 7
	if r < 0 {
		r += 7
	}
	return r
}
