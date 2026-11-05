package rrule

// Frequency is the FREQ part of a rule.
type Frequency int

// Supported frequencies.
const (
	Yearly Frequency = iota + 1
	Monthly
	Weekly
	Daily
)

// String returns the RFC 5545 name of f.
func (f Frequency) String() string {
	switch f {
	case Yearly:
		return "YEARLY"
	case Monthly:
		return "MONTHLY"
	case Weekly:
		return "WEEKLY"
	case Daily:
		return "DAILY"
	}
	return "UNKNOWN"
}

// WeekdayNum is one BYDAY entry: a weekday with an optional ordinal.
// Ordinal 0 means "every such weekday"; otherwise it selects the n-th
// (n > 0) or n-th from last (n < 0) occurrence within the month or year.
type WeekdayNum struct {
	Ordinal int
	Weekday Weekday
}

// Rule is a parsed recurrence rule. The zero value is not valid: Freq must
// be set. Interval 0 is treated as 1 and WeekStart's zero value is Monday,
// matching the RFC defaults.
//
// A Rule is immutable once built and may be shared between goroutines.
type Rule struct {
	Freq      Frequency
	Interval  int // 1–100; 0 means 1
	Count     int // 0 means unbounded (no COUNT part)
	Until     *DateTime
	WeekStart Weekday

	ByMonth    []int
	ByMonthDay []int
	ByYearDay  []int
	ByWeekNo   []int
	ByDay      []WeekdayNum
	BySetPos   []int
}
