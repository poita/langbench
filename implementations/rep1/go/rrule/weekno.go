package rrule

// weekInfo holds the week-numbering data of one calendar year for BYWEEKNO
// (SPEC step 4), computed once per year.
type weekInfo struct {
	start int // s(Y): index of the first day of week 1, from 1 January (may be negative)
	weeks int // weeks(Y): 52 or 53
	prev  int // P: week number assigned to the leading days before week 1
}

// weeksFrom returns the number of whole weeks of at least four days in a span
// of l days.
func weeksFrom(l int) int {
	w := l / 7
	if l%7 >= 4 {
		w++
	}
	return w
}

// weekStartIndex returns s(Y) for a year that begins on day number jan1.
func weekStartIndex(wkst, jan1 int) int {
	first := mod7(wkst - jan1%7)
	if first < 4 {
		return first
	}
	return first - 7
}

// yearWeekInfo computes the week data for the year whose 1 January is day
// number jan1 and whose length is ylen; prevLen is the previous year's length.
func yearWeekInfo(wkst, jan1, ylen, prevLen int) weekInfo {
	s := weekStartIndex(wkst, jan1)
	w := weekInfo{start: s, weeks: weeksFrom(ylen - s)}
	sPrev := weekStartIndex(wkst, jan1-prevLen)
	if sPrev < 0 {
		w.prev = weeksFrom(prevLen - sPrev)
	} else {
		w.prev = 52
		if (ylen-s)%7 >= 4 {
			w.prev = 53
		}
	}
	return w
}

// matches reports whether the day with 0-based year index i passes BYWEEKNO.
func (w *weekInfo) matches(c *compiled, i int) bool {
	if i < w.start { // case (b)
		return c.weekNoN[1] || c.weekNo[w.prev]
	}
	wk := (i-w.start)/7 + 1
	if wk > w.weeks { // case (c)
		return c.weekNo[1]
	}
	return c.weekNo[wk] || c.weekNoN[w.weeks+1-wk]
}
