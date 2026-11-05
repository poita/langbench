package rrule

// compiled is a rule lowered to O(1) lookup tables, with the DTSTART
// defaults of the expansion algorithm applied. Positive and negative list
// values have separate tables, so a filter is one or two array reads.
type compiled struct {
	freq     Frequency
	interval int
	wkst     int

	hasMonth, hasMonthDay, hasYearDay, hasWeekNo, hasWeekday, hasOrdinal bool

	month      [13]bool
	monthDay   [32]bool // positive month days
	monthDayN  [32]bool // negative month days, indexed by -value
	yearDay    [367]bool
	yearDayN   [367]bool
	weekNo     [54]bool
	weekNoN    [54]bool
	weekday    [7]bool
	ordinals   []WeekdayNum
	setPos     []int
	months     [12]int // months to visit in a YEARLY period, ascending
	monthCount int
}

// compile fills c from r and the start date. It reuses c's slices.
func (c *compiled) compile(r *Rule, start DateTime) {
	ords, setPos := c.ordinals[:0], c.setPos[:0]
	*c = compiled{}
	c.ordinals, c.setPos = ords, setPos

	c.freq = r.Freq
	c.interval = r.Interval
	if c.interval == 0 {
		c.interval = 1
	}
	c.wkst = int(r.WeekStart)

	for _, m := range r.ByMonth {
		c.month[m] = true
	}
	c.hasMonth = len(r.ByMonth) > 0
	for _, v := range r.ByMonthDay {
		setSigned(c.monthDay[:], c.monthDayN[:], v)
	}
	c.hasMonthDay = len(r.ByMonthDay) > 0
	for _, v := range r.ByYearDay {
		setSigned(c.yearDay[:], c.yearDayN[:], v)
	}
	c.hasYearDay = len(r.ByYearDay) > 0
	for _, v := range r.ByWeekNo {
		setSigned(c.weekNo[:], c.weekNoN[:], v)
	}
	c.hasWeekNo = len(r.ByWeekNo) > 0
	for _, d := range r.ByDay {
		if d.Ordinal != 0 {
			c.ordinals = append(c.ordinals, d)
			c.hasOrdinal = true
		} else {
			c.weekday[d.Weekday] = true
			c.hasWeekday = true
		}
	}
	c.setPos = append(c.setPos, r.BySetPos...)

	// Step 1: defaults derived from DTSTART.
	if !c.hasMonthDay && !c.hasYearDay && !c.hasWeekNo && !c.hasWeekday && !c.hasOrdinal {
		switch r.Freq {
		case Yearly:
			if !c.hasMonth {
				c.month[start.Month] = true
				c.hasMonth = true
			}
			c.monthDay[start.Day] = true
			c.hasMonthDay = true
		case Monthly:
			c.monthDay[start.Day] = true
			c.hasMonthDay = true
		case Weekly:
			c.weekday[start.Weekday()] = true
			c.hasWeekday = true
		}
	}

	for m := 1; m <= 12; m++ {
		if !c.hasMonth || c.month[m] {
			c.months[c.monthCount] = m
			c.monthCount++
		}
	}
}

// setSigned records v in the positive table, or -v in the negative table.
func setSigned(pos, neg []bool, v int) {
	if v > 0 {
		pos[v] = true
	} else {
		neg[-v] = true
	}
}
