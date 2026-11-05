package regex

// choice is a backtracking choice point. For an ordinary split lo is -1 and
// pos is the position to resume at. For a character loop, pc is the
// continuation, pos is the end currently being tried and lo the shortest
// allowed end: backtracking gives back one character at a time and the entry
// stays on the stack until pos reaches lo.
type choice struct {
	pc    int32
	pos   int32
	trail int32
	lo    int32
}

// undo records the previous value of a capture or loop-register slot.
type undo struct {
	slot int32
	old  int32
}

// Matcher holds the reusable scratch state (choice-point stack, undo trail,
// capture slots) for running a Regex over many subjects without allocating.
// A Matcher is not safe for concurrent use; use one per goroutine.
type Matcher struct {
	re    *Regex
	caps  []int32
	stack []choice
	trail []undo
	start int
	end   int
	found bool
}

// NewMatcher returns a Matcher for re.
func NewMatcher(re *Regex) *Matcher {
	m := &Matcher{}
	m.Reset(re)
	return m
}

// Reset retargets m at another Regex, keeping its allocated buffers.
func (m *Matcher) Reset(re *Regex) {
	m.re = re
	if cap(m.caps) < re.nslots {
		m.caps = make([]int32, re.nslots)
	}
	m.caps = m.caps[:re.nslots]
	m.found = false
}

// Find searches subject for the first match. On success the span and group
// positions are available through Span and Group until the next call.
func (m *Matcher) Find(subject []byte) bool {
	re := m.re
	n := len(subject)
	last := n
	if re.anchored {
		last = 0
	}
	m.found = false
	for start := 0; start <= last; start++ {
		if re.filter {
			first := re.first
			for start < n && !first[subject[start]] {
				start++
			}
			if start >= n || start > last {
				return false
			}
		}
		caps := m.caps[:re.ncaps]
		for i := range caps {
			caps[i] = -1
		}
		if end := m.run(subject, start); end >= 0 {
			m.start, m.end, m.found = start, end, true
			return true
		}
	}
	return false
}

// Span returns the bounds of the last match found.
func (m *Matcher) Span() (start, end int) { return m.start, m.end }

// Group returns the span of capture group g (1-based) in the last match.
// ok is false if the group did not participate in the match.
func (m *Matcher) Group(g int) (start, end int, ok bool) {
	s, e := m.caps[2*g], m.caps[2*g+1]
	if s < 0 || e < 0 {
		return 0, 0, false
	}
	return int(s), int(e), true
}

// run executes the program anchored at start and returns the match end, or
// -1 if the program fails at this start position.
func (m *Matcher) run(s []byte, start int) int {
	prog := m.re.prog
	classes := m.re.classes
	caps := m.caps
	stack := m.stack[:0]
	trail := m.trail[:0]
	n := len(s)
	pc, pos := 0, start

	for {
		in := &prog[pc]
		switch in.op {
		case opChar:
			if pos < n && s[pos] == byte(in.x) {
				pos++
				pc++
				continue
			}
		case opAny:
			if pos < n {
				pos++
				pc++
				continue
			}
		case opClass:
			if pos < n && classes[in.x][s[pos]] {
				pos++
				pc++
				continue
			}
		case opBol:
			if pos == 0 {
				pc++
				continue
			}
		case opEol:
			if pos == n {
				pc++
				continue
			}
		case opSplit:
			stack = append(stack, choice{pc: in.y, pos: int32(pos), trail: int32(len(trail)), lo: -1})
			pc = int(in.x)
			continue
		case opJmp:
			pc = int(in.x)
			continue
		case opSave, opMark:
			if len(stack) > 0 { // with no choice point nothing can be undone
				trail = append(trail, undo{slot: in.x, old: caps[in.x]})
			}
			caps[in.x] = int32(pos)
			pc++
			continue
		case opCheck:
			if caps[in.x] == int32(pos) {
				pc = int(in.y)
			} else {
				pc++
			}
			continue
		case opMatch:
			m.stack, m.trail = stack, trail
			return pos
		case opCharLoop:
			limit := n - pos
			if in.z >= 0 && int(in.z) < limit {
				limit = int(in.z)
			}
			min := int(in.y)
			cnt := 0
			if limit >= min {
				switch in.kind {
				case opAny:
					cnt = limit
				case opChar:
					c := byte(in.x)
					for cnt < limit && s[pos+cnt] == c {
						cnt++
					}
				default:
					set := &classes[in.x]
					for cnt < limit && set[s[pos+cnt]] {
						cnt++
					}
				}
			}
			if limit >= min && cnt >= min {
				if cnt > min {
					stack = append(stack, choice{pc: int32(pc + 1), pos: int32(pos + cnt), trail: int32(len(trail)), lo: int32(pos + min)})
				}
				pos += cnt
				pc++
				continue
			}
		}

		// Failure: resume at the newest choice point.
		if len(stack) == 0 {
			m.stack, m.trail = stack, trail
			return -1
		}
		top := &stack[len(stack)-1]
		for tl := int(top.trail); len(trail) > tl; {
			e := trail[len(trail)-1]
			caps[e.slot] = e.old
			trail = trail[:len(trail)-1]
		}
		pc = int(top.pc)
		if top.lo >= 0 {
			top.pos--
			pos = int(top.pos)
			if top.pos <= top.lo {
				stack = stack[:len(stack)-1]
			}
		} else {
			pos = int(top.pos)
			stack = stack[:len(stack)-1]
		}
	}
}
