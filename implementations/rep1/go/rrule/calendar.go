package rrule

// Calendar arithmetic on the proleptic Gregorian calendar.
//
// Dates are represented internally as day numbers: the number of days since
// 0001-01-01, which is day 0 and a Monday. Consequently the weekday of a day
// number is simply dayNumber mod 7 with Monday = 0. All conversions are O(1).

const (
	daysPer400Years = 146097
	daysPer100Years = 36524
	daysPer4Years   = 1461
	secondsPerDay   = 86400
)

// monthLen[leap][m] is the number of days in month m (1-12).
var monthLen = [2][13]int{
	{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
	{0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
}

// monthStart[leap][m] is the 0-based day of year of the first day of month m.
var monthStart [2][14]int

// monthOfYday[leap][i] is the month (1-12) containing 0-based day of year i.
var monthOfYday [2][366]uint8

func init() {
	for l := 0; l < 2; l++ {
		acc := 0
		for m := 1; m <= 12; m++ {
			monthStart[l][m] = acc
			for i := 0; i < monthLen[l][m]; i++ {
				monthOfYday[l][acc+i] = uint8(m)
			}
			acc += monthLen[l][m]
		}
		monthStart[l][13] = acc
	}
}

// IsLeapYear reports whether y is a leap year in the proleptic Gregorian
// calendar.
func IsLeapYear(y int) bool {
	return y%4 == 0 && (y%100 != 0 || y%400 == 0)
}

func leapIndex(y int) int {
	if IsLeapYear(y) {
		return 1
	}
	return 0
}

// DaysInMonth returns the number of days in the given month (1-12) of year y.
func DaysInMonth(y, m int) int {
	return monthLen[leapIndex(y)][m]
}

// DaysInYear returns 365 or 366.
func DaysInYear(y int) int {
	return 365 + leapIndex(y)
}

// daysFromYear returns the day number of 1 January of year y.
func daysFromYear(y int) int {
	p := y - 1
	return 365*p + p/4 - p/100 + p/400
}

// daysFromCivil returns the day number of the given date.
func daysFromCivil(y, m, d int) int {
	return daysFromYear(y) + monthStart[leapIndex(y)][m] + d - 1
}

// civilFromDays converts a day number (>= 0) into year, month, day and the
// 0-based day of the year.
func civilFromDays(n int) (y, m, d, yday int) {
	n400 := n / daysPer400Years
	r := n % daysPer400Years
	n100 := r / daysPer100Years
	if n100 > 3 {
		n100 = 3
	}
	r -= n100 * daysPer100Years
	n4 := r / daysPer4Years
	r %= daysPer4Years
	n1 := r / 365
	if n1 > 3 {
		n1 = 3
	}
	r -= n1 * 365
	y = n400*400 + n100*100 + n4*4 + n1 + 1
	l := leapIndex(y)
	m = int(monthOfYday[l][r])
	d = r - monthStart[l][m] + 1
	return y, m, d, r
}

// weekdayOf returns the weekday (Monday = 0) of a day number.
func weekdayOf(n int) int {
	w := n % 7
	if w < 0 {
		w += 7
	}
	return w
}

// mod7 returns x mod 7 in the range 0-6 for any integer x.
func mod7(x int) int {
	x %= 7
	if x < 0 {
		x += 7
	}
	return x
}

// floorDiv returns the floor of a/b for b > 0.
func floorDiv(a, b int) int {
	q := a / b
	if a%b < 0 {
		q--
	}
	return q
}
