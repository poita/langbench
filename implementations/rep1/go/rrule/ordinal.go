package rrule

// markOrdinals marks, in e.ordMask, the days designated by the ordinal BYDAY
// codes within the range of length n starting at day number first. Marks are
// stored at index base+offset-in-range and recorded in e.ordMarked so they
// can be cleared cheaply.
func (e *Expander) markOrdinals(first, n, base int) {
	startWd := first % 7
	lastWd := (first + n - 1) % 7
	for _, o := range e.c.ordinals {
		x := int(o.Weekday)
		var pos int
		if o.Ordinal > 0 {
			pos = mod7(x-startWd) + 7*(o.Ordinal-1)
		} else {
			pos = n - 1 - mod7(lastWd-x) - 7*(-o.Ordinal-1)
		}
		if pos >= 0 && pos < n {
			e.ordMask[base+pos] = true
			e.ordMarked = append(e.ordMarked, base+pos)
		}
	}
}

// clearOrdinals resets the marks made by markOrdinals.
func (e *Expander) clearOrdinals() {
	for _, i := range e.ordMarked {
		e.ordMask[i] = false
	}
	e.ordMarked = e.ordMarked[:0]
}
