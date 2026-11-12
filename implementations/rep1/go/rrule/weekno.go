package rrule

// Week numbering for BYWEEKNO (SPEC.md section 4).
//
// Weeks start on the rule's WKST. Week 1 of a year is the first week with at
// least four days in that year.

// weekYear holds the week-numbering facts of one calendar year that are needed
// to classify each of its days in O(1).
type weekYear struct {
	s     int // 0-based day of year on which week 1 starts (may be negative)
	weeks int // number of weeks, 52 or 53
	prev  int // week number given to the days before week 1 (case b)
}

// weekStartOffset returns s(y): the day index (from 1 January) at which week 1
// of year y starts.
func weekStartOffset(y int, wkst Weekday) int {
	first := mod7(int(wkst) - weekdayOf(daysFromYear(y)))
	if first < 4 {
		return first
	}
	return first - 7
}

// weeksInYear returns the number of weeks of year y given s(y).
func weeksInYear(y, s int) int {
	l := DaysInYear(y) - s
	n := l / 7
	if l%7 >= 4 {
		n++
	}
	return n
}

func newWeekYear(y int, wkst Weekday) weekYear {
	s := weekStartOffset(y, wkst)
	w := weekYear{s: s, weeks: weeksInYear(y, s)}
	if s > 0 {
		sPrev := weekStartOffset(y-1, wkst)
		if sPrev < 0 {
			w.prev = weeksInYear(y-1, sPrev)
		} else {
			w.prev = 52
			if (DaysInYear(y)-s)%7 >= 4 {
				w.prev = 53
			}
		}
	}
	return w
}

// weekSet is the BYWEEKNO filter as two lookup tables indexed by |value|.
type weekSet struct {
	pos, neg [55]bool
}

// matches reports whether the day with 0-based day-of-year index i of the year
// described by w is selected.
func (ws *weekSet) matches(w *weekYear, i int) bool {
	if i < w.s {
		return ws.neg[1] || ws.pos[w.prev]
	}
	k := (i-w.s)/7 + 1
	if k <= w.weeks {
		return ws.pos[k] || ws.neg[w.weeks+1-k]
	}
	return ws.pos[1]
}
