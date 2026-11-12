package rrule

import (
	"errors"
	"sort"
)

// maxDay is the last day number that may be enumerated: 31 December 9999.
var maxDay = daysFromYear(10000) - 1

// plan is a Rule compiled against a DTSTART: defaults applied and every
// filter turned into a lookup table so that testing a day is O(1).
type plan struct {
	freq     Frequency
	interval int
	wkst     int
	count    int

	hasUntil bool
	until    int64 // DateTime.ordinal() of UNTIL

	startDay int   // day number of DTSTART
	tod      int   // DTSTART's time of day in seconds
	startOrd int64 // DTSTART as an ordinal
	startY   int
	startM   int

	hasMonth    bool
	months      [13]bool
	hasMonthDay bool
	mdayPos     [32]bool
	mdayNeg     [32]bool
	hasYearDay  bool
	ydayPos     [367]bool
	ydayNeg     [367]bool
	hasWeekNo   bool
	weekNo      weekSet
	hasWeekday  bool
	weekdays    [7]bool
	ordinals    []WeekdaySpec
	setPos      []int
}

func compile(r *Rule, start DateTime) (*plan, error) {
	if err := r.Validate(); err != nil {
		return nil, err
	}
	if !start.Valid() {
		return nil, errors.New("rrule: invalid DTSTART")
	}
	p := &plan{
		freq: r.Freq, interval: r.Interval, wkst: int(r.WeekStart),
		count: r.Count, hasUntil: r.HasUntil,
		startDay: daysFromCivil(start.Year, start.Month, start.Day),
		tod:      start.timeOfDay(),
		startY:   start.Year, startM: start.Month,
		setPos: r.BySetPos,
	}
	p.startOrd = start.ordinal()
	if r.HasUntil {
		p.until = r.Until.ordinal()
	}

	monthDays := r.ByMonthDay
	months := r.ByMonth
	byDay := r.ByDay
	// Step 1: defaults derived from DTSTART.
	if len(r.ByMonthDay) == 0 && len(r.ByYearDay) == 0 && len(r.ByWeekNo) == 0 && len(r.ByDay) == 0 {
		switch r.Freq {
		case Yearly:
			if len(months) == 0 {
				months = []int{start.Month}
			}
			monthDays = []int{start.Day}
		case Monthly:
			monthDays = []int{start.Day}
		case Weekly:
			byDay = []WeekdaySpec{{Day: start.Weekday()}}
		}
	}

	if len(months) > 0 {
		p.hasMonth = true
		for _, m := range months {
			p.months[m] = true
		}
	}
	if len(monthDays) > 0 {
		p.hasMonthDay = true
		for _, d := range monthDays {
			if d > 0 {
				p.mdayPos[d] = true
			} else {
				p.mdayNeg[-d] = true
			}
		}
	}
	if len(r.ByYearDay) > 0 {
		p.hasYearDay = true
		for _, d := range r.ByYearDay {
			if d > 0 {
				p.ydayPos[d] = true
			} else {
				p.ydayNeg[-d] = true
			}
		}
	}
	if len(r.ByWeekNo) > 0 {
		p.hasWeekNo = true
		for _, w := range r.ByWeekNo {
			if w > 0 {
				p.weekNo.pos[w] = true
			} else {
				p.weekNo.neg[-w] = true
			}
		}
	}
	for _, s := range byDay {
		if s.N == 0 {
			p.hasWeekday = true
			p.weekdays[s.Day] = true
		} else {
			p.ordinals = append(p.ordinals, s)
		}
	}
	return p, nil
}

// period describes the candidate days of one period: n consecutive days
// starting at day number first.
type period struct {
	first, n int
}

// periodAt returns period k, or ok=false when enumeration is over because the
// period would start after year 9999.
func (p *plan) periodAt(k int) (per period, ok bool) {
	switch p.freq {
	case Yearly:
		y := p.startY + k*p.interval
		if y > 9999 {
			return period{}, false
		}
		return period{daysFromYear(y), DaysInYear(y)}, true
	case Monthly:
		idx := p.startY*12 + (p.startM - 1) + k*p.interval
		y, m := idx/12, idx%12+1
		if y > 9999 {
			return period{}, false
		}
		return period{daysFromCivil(y, m, 1), DaysInMonth(y, m)}, true
	case Weekly:
		a := p.startDay - mod7(weekdayOf(p.startDay)-p.wkst)
		var per period
		if k == 0 {
			per = period{p.startDay, 7 - (p.startDay - a)}
		} else {
			per = period{a + 7*k*p.interval, 7}
		}
		return per, per.first <= maxDay
	default: // Daily
		d := p.startDay + k*p.interval
		return period{d, 1}, d <= maxDay
	}
}

// markOrdinals fills marks[0:per.n] with the days designated by the ordinal
// BYDAY codes (SPEC.md section 5).
func (p *plan) markOrdinals(per period, marks []bool) {
	for i := range marks[:per.n] {
		marks[i] = false
	}
	if p.freq == Monthly || !p.hasMonth {
		// The whole period (month or year) is the range.
		p.markRange(per.first, per.n, per.first, marks)
		return
	}
	y, _, _, _ := civilFromDays(per.first)
	l := leapIndex(y)
	for m := 1; m <= 12; m++ {
		if p.months[m] {
			p.markRange(per.first+monthStart[l][m], monthLen[l][m], per.first, marks)
		}
	}
}

// markRange marks, for each ordinal code, its designated day within the range
// of n days starting at day number start. base is the day number of marks[0].
func (p *plan) markRange(start, n, base int, marks []bool) {
	last := start + n - 1
	for _, s := range p.ordinals {
		wd := int(s.Day)
		var day int
		if s.N > 0 {
			day = start + mod7(wd-weekdayOf(start)) + 7*(s.N-1)
		} else {
			day = last - mod7(weekdayOf(last)-wd) + 7*(s.N+1)
		}
		if day >= start && day <= last {
			marks[day-base] = true
		}
	}
}

// Each calls yield with the occurrences of the rule for the given DTSTART in
// chronological order, until yield returns false, the rule is exhausted, or
// limit occurrences have been produced. A limit of zero or less means no
// limit other than those of the rule itself. Occurrences never fall after
// 31 December 9999.
//
// Every period is enumerated and each of its days is tested against the
// filters in constant time; the cost is O(periods + days + occurrences).
func (r Rule) Each(start DateTime, limit int, yield func(DateTime) bool) error {
	p, err := compile(&r, start)
	if err != nil {
		return err
	}
	p.run(limit, func(day int) bool {
		y, m, d, _ := civilFromDays(day)
		return yield(DateTime{y, m, d, start.Hour, start.Minute, start.Second})
	})
	return nil
}

// Expand returns up to limit occurrences of the rule (all of them if limit is
// zero or less). See Each for the semantics.
func (r Rule) Expand(start DateTime, limit int) ([]DateTime, error) {
	var out []DateTime
	err := r.Each(start, limit, func(t DateTime) bool {
		out = append(out, t)
		return true
	})
	return out, err
}

// run walks the periods and reports occurrence day numbers (SPEC.md
// sections 2, 3, 6 and 7).
func (p *plan) run(limit int, emit func(day int) bool) {
	emitted := 0
	// offer applies the UNTIL / DTSTART / COUNT / limit rules of section 7 to
	// one occurrence. It returns false when the expansion must stop.
	offer := func(day int) bool {
		ord := int64(day)*secondsPerDay + int64(p.tod)
		if p.hasUntil && ord > p.until {
			return false
		}
		if ord < p.startOrd {
			return true
		}
		if !emit(day) {
			return false
		}
		emitted++
		return !(p.count > 0 && emitted >= p.count) && !(limit > 0 && emitted >= limit)
	}

	var marks []bool
	if len(p.ordinals) > 0 {
		marks = make([]bool, 366)
	}
	var kept []int
	var picks []int

	for k := 0; ; k++ {
		per, ok := p.periodAt(k)
		if !ok {
			return
		}
		if p.hasUntil && int64(per.first)*secondsPerDay+int64(p.tod) > p.until {
			return
		}
		if marks != nil {
			p.markOrdinals(per, marks)
		}

		y, m, d, yd := civilFromDays(per.first)
		leap := leapIndex(y)
		ml := monthLen[leap][m]
		yl := 365 + leap
		wd := weekdayOf(per.first)
		var wy weekYear
		if p.hasWeekNo {
			wy = newWeekYear(y, Weekday(p.wkst))
		}
		kept = kept[:0]

		for off := 0; off < per.n; off++ {
			keep := (!p.hasMonth || p.months[m]) &&
				(!p.hasWeekNo || p.weekNo.matches(&wy, yd)) &&
				(!p.hasWeekday || p.weekdays[wd]) &&
				(marks == nil || marks[off]) &&
				(!p.hasMonthDay || p.mdayPos[d] || p.mdayNeg[ml-d+1]) &&
				(!p.hasYearDay || p.ydayPos[yd+1] || p.ydayNeg[yl-yd])
			if keep {
				if len(p.setPos) > 0 {
					kept = append(kept, per.first+off)
				} else if !offer(per.first + off) {
					return
				}
			}
			// Advance to the next day.
			wd++
			if wd == 7 {
				wd = 0
			}
			yd++
			if d++; d > ml {
				d = 1
				if m++; m > 12 {
					m = 1
					y++
					yd = 0
					leap = leapIndex(y)
					yl = 365 + leap
				}
				ml = monthLen[leap][m]
			}
		}

		if len(p.setPos) > 0 {
			picks = picks[:0]
			for _, sp := range p.setPos {
				idx := sp - 1
				if sp < 0 {
					idx = len(kept) + sp
				}
				if idx >= 0 && idx < len(kept) {
					picks = append(picks, idx)
				}
			}
			sort.Ints(picks)
			for i, idx := range picks {
				if i > 0 && idx == picks[i-1] {
					continue
				}
				if !offer(kept[idx]) {
					return
				}
			}
		}
	}
}
