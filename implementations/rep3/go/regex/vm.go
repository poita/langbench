package regex

import "regex/prog"

// choice is a backtracking choice point. For a split (lo < 0) it resumes at
// pc with position pos. For a character loop (lo >= 0) pos is the current
// end of the loop, lo its lowest allowed end, and pc the instruction after
// the loop; backtracking gives back one character at a time.
type choice struct {
	pc, pos, trail, lo int32
}

// undo records the previous value of a capture slot or loop register.
type undo struct {
	slot, old int32
}

// Find searches b for the first match, trying start positions left to right.
// On success the match and group offsets are available through Start, End
// and Group, and Find returns true.
func (m *Matcher) Find(b []byte) bool {
	p := m.re.prog
	insts := p.Insts
	sets := p.Sets
	caps := m.caps
	ncaps := int32(p.NumCaps)
	for i := range caps[:ncaps] {
		caps[i] = -1
	}
	stack := m.stack[:0]
	trail := m.trail[:0]
	n := len(b)
	first := p.First

	for start := 0; start <= n; start++ {
		if first != nil {
			for start < n && !first[b[start]] {
				start++
			}
			if start >= n {
				break // a non-nullable pattern cannot match at the end
			}
		}
		if p.Anchored && start > 0 {
			break
		}
		pc := int32(0)
		pos := start
		stack = stack[:0]
		trail = trail[:0]

		for {
			ok := true
			in := &insts[pc]
			switch in.Op {
			case prog.OpChar:
				if pos < n && int32(b[pos]) == in.A {
					pos++
					pc++
				} else {
					ok = false
				}
			case prog.OpAny:
				if pos < n {
					pos++
					pc++
				} else {
					ok = false
				}
			case prog.OpClass:
				if pos < n && sets[in.A][b[pos]] {
					pos++
					pc++
				} else {
					ok = false
				}
			case prog.OpBOL:
				if pos == 0 {
					pc++
				} else {
					ok = false
				}
			case prog.OpEOL:
				if pos == n {
					pc++
				} else {
					ok = false
				}
			case prog.OpSplit:
				stack = append(stack, choice{in.B, int32(pos), int32(len(trail)), -1})
				pc = in.A
			case prog.OpJmp:
				pc = in.A
			case prog.OpSave:
				trail = append(trail, undo{in.A, caps[in.A]})
				caps[in.A] = int32(pos)
				pc++
			case prog.OpMark:
				slot := ncaps + in.A
				trail = append(trail, undo{slot, caps[slot]})
				caps[slot] = int32(pos)
				pc++
			case prog.OpCheck:
				if caps[ncaps+in.A] == int32(pos) {
					pc = in.B
				} else {
					pc++
				}
			case prog.OpCharLoop:
				lo := pos + int(in.B)
				limit := n
				if in.C >= 0 && pos+int(in.C) < n {
					limit = pos + int(in.C)
				}
				cur := pos
				if in.A < 0 {
					cur = limit
				} else {
					set := &sets[in.A]
					for cur < limit && set[b[cur]] {
						cur++
					}
				}
				if cur < lo {
					ok = false
				} else {
					if cur > lo {
						stack = append(stack, choice{pc + 1, int32(cur), int32(len(trail)), int32(lo)})
					}
					pos = cur
					pc++
				}
			case prog.OpMatch:
				m.start, m.end = start, pos
				m.stack, m.trail = stack, trail
				return true
			}
			if ok {
				continue
			}

			// Backtrack to the newest choice point.
			if len(stack) == 0 {
				for i := len(trail) - 1; i >= 0; i-- {
					caps[trail[i].slot] = trail[i].old
				}
				break
			}
			top := &stack[len(stack)-1]
			for tl := int(top.trail); len(trail) > tl; {
				u := trail[len(trail)-1]
				caps[u.slot] = u.old
				trail = trail[:len(trail)-1]
			}
			pc = top.pc
			if top.lo >= 0 {
				pos = int(top.pos) - 1
				if int32(pos) > top.lo {
					top.pos = int32(pos)
				} else {
					stack = stack[:len(stack)-1]
				}
			} else {
				pos = int(top.pos)
				stack = stack[:len(stack)-1]
			}
		}
	}
	m.stack, m.trail = stack, trail
	return false
}
