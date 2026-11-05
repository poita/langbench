package rrule

import "fmt"

// Expander expands rules. It owns the scratch buffers the algorithm needs,
// so reusing one Expander across many rules avoids all per-period and
// per-rule allocation. An Expander must not be used concurrently; a Rule can
// be shared freely.
type Expander struct {
	c compiled

	// Per-expansion emit state.
	dtDay    int  // day number of DTSTART
	lastDay  int  // last day number that may be printed (when hasUntil)
	hasUntil bool // UNTIL present
	limit    int  // combined COUNT / N limit
	printed  int
	yield    func(day int) bool

	// Reused scratch buffers.
	kept      []int // kept day numbers of the current period
	sel       []int // BYSETPOS selection indices
	ordMask   [366]bool
	ordMarked []int
	week      weekInfo
}

// NewExpander returns an Expander ready for use.
func NewExpander() *Expander { return &Expander{} }

// cursor is an incremental calendar position: advancing it by one day is an
// increment with month and year rollover, never a full date conversion.
type cursor struct {
	day   int // day number
	year  int
	month int
	dom   int // day of month, 1-based
	doy   int // day of year, 0-based
	mlen  int // length of the current month
	ylen  int // length of the current year
	wd    int // weekday, Monday = 0
}

// cursorAt builds a cursor for an arbitrary day number using the closed-form
// conversion.
func cursorAt(day int) cursor {
	y, m, d := civilFromDay(day)
	return cursor{
		day: day, year: y, month: m, dom: d,
		doy:  day - daysBeforeYear(y),
		mlen: DaysInMonth(y, m), ylen: DaysInYear(y),
		wd: day % 7,
	}
}

func (c *cursor) advance() {
	c.day++
	c.doy++
	c.dom++
	c.wd++
	if c.wd == 7 {
		c.wd = 0
	}
	if c.dom > c.mlen {
		c.dom = 1
		c.month++
		if c.month > 12 {
			c.month = 1
			c.year++
			c.doy = 0
			c.ylen = DaysInYear(c.year)
		}
		c.mlen = DaysInMonth(c.year, c.month)
	}
}

// Each calls fn for each occurrence of r from start, in chronological order,
// until at most n occurrences have been produced (and never more than the
// rule's COUNT) or fn returns false.
func (e *Expander) Each(r *Rule, start DateTime, n int, fn func(DateTime) bool) error {
	return e.run(r, start, n, func(day int) bool {
		y, m, d := civilFromDay(day)
		return fn(DateTime{y, m, d, start.Hour, start.Minute, start.Second})
	})
}

// Expand returns up to n occurrences of r from start.
func (e *Expander) Expand(r *Rule, start DateTime, n int) ([]DateTime, error) {
	var out []DateTime
	err := e.Each(r, start, n, func(dt DateTime) bool {
		out = append(out, dt)
		return true
	})
	return out, err
}

// AppendText appends the occurrences as YYYYMMDDTHHMMSS stamps separated by
// single spaces (no trailing newline) and returns the extended slice.
func (e *Expander) AppendText(dst []byte, r *Rule, start DateTime, n int) ([]byte, error) {
	secs := start.secondsOfDay()
	first := true
	err := e.run(r, start, n, func(day int) bool {
		if !first {
			dst = append(dst, ' ')
		}
		first = false
		y, m, d := civilFromDay(day)
		dst = appendStamp(dst, y, m, d, secs)
		return true
	})
	return dst, err
}

// Expand returns up to n occurrences of r from start; see [Expander.Expand].
func (r *Rule) Expand(start DateTime, n int) ([]DateTime, error) {
	return NewExpander().Expand(r, start, n)
}

// run is the expansion engine; it reports each occurrence as a day number.
func (e *Expander) run(r *Rule, start DateTime, n int, yield func(day int) bool) error {
	if err := r.Validate(); err != nil {
		return err
	}
	if !start.Valid() {
		return fmt.Errorf("%w: DTSTART %+v", ErrInvalidDateTime, start)
	}
	e.limit = n
	if r.Count > 0 && r.Count < e.limit {
		e.limit = r.Count
	}
	if e.limit <= 0 {
		return nil
	}
	e.c.compile(r, start)
	e.dtDay = dayNumber(start.Year, start.Month, start.Day)
	e.hasUntil = r.Until != nil
	if e.hasUntil {
		e.lastDay = dayNumber(r.Until.Year, r.Until.Month, r.Until.Day)
		if r.Until.secondsOfDay() < start.secondsOfDay() {
			e.lastDay--
		}
	}
	e.printed = 0
	e.yield = yield
	e.ordMarked = e.ordMarked[:0]

	switch e.c.freq {
	case Yearly:
		e.runYearly(start)
	case Monthly:
		e.runMonthly(start)
	case Weekly:
		e.runWeekly()
	case Daily:
		e.runDaily()
	}
	e.yield = nil
	return nil
}

// pastUntil reports whether a period whose first day is startDay can be
// abandoned because nothing in it can be printed.
func (e *Expander) pastUntil(startDay int) bool {
	return e.hasUntil && startDay > e.lastDay
}

func (e *Expander) runYearly(start DateTime) {
	c := &e.c
	prevLen := DaysInYear(start.Year - 1)
	for y := start.Year; y <= maxYear; y += c.interval {
		ylen := DaysInYear(y)
		jan1 := daysBeforeYear(y)
		if y != start.Year {
			prevLen = DaysInYear(y - 1)
		}
		if e.pastUntil(jan1) {
			return
		}
		if c.hasWeekNo {
			e.week = yearWeekInfo(c.wkst, jan1, ylen, prevLen)
		}
		if c.hasOrdinal && !c.hasMonth {
			e.markOrdinals(jan1, ylen, 0)
		}
		leap := ylen == 366
		e.kept = e.kept[:0]
		for _, m := range c.months[:c.monthCount] {
			doy := daysBeforeMonth[m]
			mlen := monthLengths[m]
			if leap && m > 2 {
				doy++
			}
			if leap && m == 2 {
				mlen = 29
			}
			if c.hasOrdinal && c.hasMonth {
				e.markOrdinals(jan1+doy, mlen, doy)
			}
			cur := cursor{
				day: jan1 + doy, year: y, month: m, dom: 1, doy: doy,
				mlen: mlen, ylen: ylen, wd: (jan1 + doy) % 7,
			}
			e.walk(cur, mlen, true)
		}
		e.clearOrdinals()
		if e.finishPeriod() {
			return
		}
	}
}

func (e *Expander) runMonthly(start DateTime) {
	c := &e.c
	idx0 := start.Year*12 + start.Month - 1
	step := c.interval
	for idx := idx0; ; idx += step {
		y, m := idx/12, idx%12+1
		if y > maxYear {
			return
		}
		first := dayNumber(y, m, 1)
		if e.pastUntil(first) {
			return
		}
		if c.hasMonth && !c.month[m] {
			continue
		}
		cur := cursorAt(first)
		if c.hasOrdinal {
			e.markOrdinals(first, cur.mlen, 0)
		}
		e.kept = e.kept[:0]
		e.walk(cur, cur.mlen, false)
		e.clearOrdinals()
		if e.finishPeriod() {
			return
		}
	}
}

func (e *Expander) runWeekly() {
	c := &e.c
	end := daysBeforeYear(maxYear + 1)
	anchor := e.dtDay - mod7(e.dtDay%7-c.wkst)
	for k := 0; ; k++ {
		first, length := e.dtDay, anchor+7-e.dtDay
		if k > 0 {
			first, length = anchor+7*k*c.interval, 7
		}
		if first >= end || e.pastUntil(first) {
			return
		}
		e.kept = e.kept[:0]
		e.walk(cursorAt(first), length, false)
		if e.finishPeriod() {
			return
		}
	}
}

func (e *Expander) runDaily() {
	c := &e.c
	end := daysBeforeYear(maxYear + 1)
	for day := e.dtDay; day < end; day += c.interval {
		if e.pastUntil(day) {
			return
		}
		e.kept = e.kept[:0]
		e.walk(cursorAt(day), 1, false)
		if e.finishPeriod() {
			return
		}
	}
}

// walk examines n consecutive candidate days starting at cur and appends the
// ones that pass every filter to e.kept. ordByDoy says whether the ordinal
// mask is indexed by day of year (YEARLY) or by day of month (MONTHLY).
func (e *Expander) walk(cur cursor, n int, ordByDoy bool) {
	c := &e.c
	for i := 0; i < n; i++ {
		if c.hasMonth && !c.month[cur.month] {
			goto next
		}
		if c.hasMonthDay && !c.monthDay[cur.dom] && !c.monthDayN[cur.mlen-cur.dom+1] {
			goto next
		}
		if c.hasWeekday && !c.weekday[cur.wd] {
			goto next
		}
		if c.hasOrdinal {
			idx := cur.dom - 1
			if ordByDoy {
				idx = cur.doy
			}
			if !e.ordMask[idx] {
				goto next
			}
		}
		if c.hasYearDay && !c.yearDay[cur.doy+1] && !c.yearDayN[cur.ylen-cur.doy] {
			goto next
		}
		if c.hasWeekNo && !e.week.matches(c, cur.doy) {
			goto next
		}
		e.kept = append(e.kept, cur.day)
	next:
		cur.advance()
	}
}

// finishPeriod applies BYSETPOS to e.kept and emits the period's
// occurrences. It reports whether the whole expansion is finished.
func (e *Expander) finishPeriod() bool {
	c := &e.c
	if len(c.setPos) == 0 {
		for _, day := range e.kept {
			if e.emit(day) {
				return true
			}
		}
		return false
	}
	l := len(e.kept)
	e.sel = e.sel[:0]
	for _, p := range c.setPos {
		i := p - 1
		if p < 0 {
			i = l + p
		}
		if i < 0 || i >= l {
			continue
		}
		// Insertion into a sorted list; duplicates are skipped below.
		j := len(e.sel)
		e.sel = append(e.sel, i)
		for ; j > 0 && e.sel[j-1] > i; j-- {
			e.sel[j] = e.sel[j-1]
		}
		e.sel[j] = i
	}
	prev := -1
	for _, i := range e.sel {
		if i == prev {
			continue
		}
		prev = i
		if e.emit(e.kept[i]) {
			return true
		}
	}
	return false
}

// emit applies the UNTIL / DTSTART / limit rules of SPEC step 7 to one
// occurrence. It reports whether the expansion must stop.
func (e *Expander) emit(day int) bool {
	if e.hasUntil && day > e.lastDay {
		return true
	}
	if day < e.dtDay {
		return false
	}
	if !e.yield(day) {
		return true
	}
	e.printed++
	return e.printed >= e.limit
}
