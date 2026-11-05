package regexvm

// frame is a choice point on the backtracking stack.
type frame struct {
	pc    int32 // resume address (split) or the charloop instruction
	pos   int32 // subject position to resume at (charloop: the end just taken)
	trail int32 // trail length to restore
	lo    int32 // -1 for a split; for a charloop, the lowest allowed end
}

// trailEntry records a slot's old value for undo on backtracking.
type trailEntry struct {
	slot int32
	old  int32
}

// Matcher executes a Regexp against subjects, reusing its scratch buffers
// between calls. The zero value is ready to use after Reset. A Matcher must
// not be used concurrently.
type Matcher struct {
	re         *Regexp
	slots      []int32
	stack      []frame
	trail      []trailEntry
	start, end int
	matched    bool
}

// NewMatcher returns a Matcher bound to re.
func NewMatcher(re *Regexp) *Matcher {
	m := new(Matcher)
	m.Reset(re)
	return m
}

// Reset binds the Matcher to re, keeping its allocated buffers.
func (m *Matcher) Reset(re *Regexp) {
	m.re = re
	if cap(m.slots) < re.nslots {
		m.slots = make([]int32, re.nslots)
	}
	m.slots = m.slots[:re.nslots]
	m.matched = false
}

// Match searches subject for the first match. It reports whether one was
// found; the result is then available through Start, End and Group.
func (m *Matcher) Match(subject []byte) bool {
	re := m.re
	n := len(subject)
	m.matched = false
	ncap := 2 * re.ngroups
	last := n
	if re.anchored {
		last = 0
	}
	filter := re.filter
	for start := 0; start <= last; start++ {
		if filter != nil {
			for start < n && !filter[subject[start]] {
				start++
			}
			if start >= n {
				return false // a non-nullable pattern cannot match at n
			}
		}
		caps := m.slots[:ncap]
		for i := range caps {
			caps[i] = -1
		}
		if end, ok := m.run(subject, start); ok {
			m.start, m.end, m.matched = start, end, true
			return true
		}
	}
	return false
}

// Start returns the start offset of the last match.
func (m *Matcher) Start() int { return m.start }

// End returns the exclusive end offset of the last match.
func (m *Matcher) End() int { return m.end }

// Group returns the span of capture group g (1-based) in the last match.
// ok is false if the group did not participate or g is out of range.
func (m *Matcher) Group(g int) (start, end int, ok bool) {
	if !m.matched || g < 1 || g > m.re.ngroups {
		return 0, 0, false
	}
	s, e := m.slots[2*(g-1)], m.slots[2*(g-1)+1]
	if s < 0 || e < 0 {
		return 0, 0, false
	}
	return int(s), int(e), true
}

// run executes the program from pos. It returns the match end on success.
func (m *Matcher) run(s []byte, pos int) (int, bool) {
	re := m.re
	insts := re.insts
	classes := re.classes
	slots := m.slots
	stack := m.stack[:0]
	trail := m.trail[:0]
	n := len(s)
	pc := 0
	for {
		in := &insts[pc]
		ok := true
		switch in.op {
		case opChar:
			if pos < n && s[pos] == in.ch {
				pos++
				pc++
			} else {
				ok = false
			}
		case opAny:
			if pos < n {
				pos++
				pc++
			} else {
				ok = false
			}
		case opClass:
			if pos < n && classes[in.x][s[pos]] {
				pos++
				pc++
			} else {
				ok = false
			}
		case opBol:
			if pos == 0 {
				pc++
			} else {
				ok = false
			}
		case opEol:
			if pos == n {
				pc++
			} else {
				ok = false
			}
		case opSplit:
			stack = append(stack, frame{pc: in.y, pos: int32(pos), trail: int32(len(trail)), lo: -1})
			pc = int(in.x)
		case opJmp:
			pc = int(in.x)
		case opSave, opMark:
			if len(stack) > 0 {
				trail = append(trail, trailEntry{in.x, slots[in.x]})
			}
			slots[in.x] = int32(pos)
			pc++
		case opCheck:
			if int(slots[in.x]) == pos {
				pc = int(in.y)
			} else {
				pc++
			}
		case opCharLoop:
			lo := pos + int(in.min)
			limit := n
			if in.max >= 0 && pos+int(in.max) < n {
				limit = pos + int(in.max)
			}
			end := pos
			switch in.kind {
			case kindAny:
				end = limit
			case kindChar:
				for end < limit && s[end] == in.ch {
					end++
				}
			default:
				tbl := classes[in.x]
				for end < limit && tbl[s[end]] {
					end++
				}
			}
			if end < lo {
				ok = false
				break
			}
			if end > lo {
				stack = append(stack, frame{pc: int32(pc), pos: int32(end), trail: int32(len(trail)), lo: int32(lo)})
			}
			pos = end
			pc++
		case opMatch:
			m.stack, m.trail = stack, trail
			return pos, true
		}
		if ok {
			continue
		}
		// Backtrack to the newest choice point.
		if len(stack) == 0 {
			m.stack, m.trail = stack, trail
			return 0, false
		}
		f := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		for t := int(f.trail); len(trail) > t; {
			e := trail[len(trail)-1]
			trail = trail[:len(trail)-1]
			slots[e.slot] = e.old
		}
		if f.lo >= 0 {
			// give back one character of a charloop
			pos = int(f.pos) - 1
			if int32(pos) > f.lo {
				f.pos = int32(pos)
				stack = append(stack, f)
			}
			pc = int(f.pc) + 1
		} else {
			pos = int(f.pos)
			pc = int(f.pc)
		}
	}
}
