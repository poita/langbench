package regexbt

// frame is a saved choice point: resume at pc with the subject cursor at pos
// after undoing register writes back to trail length trail.
type frame struct {
	pc, pos, trail int
}

// undo records the previous value of a register so it can be restored.
type undo struct {
	reg, old int
}

// machine is the backtracking interpreter. It keeps an explicit stack, so
// subject length is bounded by memory rather than by the goroutine stack.
//
// Invariant between calls to match: every register is -1 and the stack and
// trail are empty.
type machine struct {
	regs  []int
	stack []frame
	trail []undo
}

func newMachine(nregs int) *machine {
	m := &machine{regs: make([]int, nregs)}
	for i := range m.regs {
		m.regs[i] = -1
	}
	return m
}

// unwind restores registers to the state they had when the trail had length n.
func (m *machine) unwind(n int) {
	for i := len(m.trail) - 1; i >= n; i-- {
		u := m.trail[i]
		m.regs[u.reg] = u.old
	}
	m.trail = m.trail[:n]
}

func (m *machine) set(reg, v int) {
	m.trail = append(m.trail, undo{reg, m.regs[reg]})
	m.regs[reg] = v
}

// match runs p anchored at start. On success it returns the end position
// and leaves the capture registers populated (call reset afterwards).
func (m *machine) match(p *prog, s string, start int) (end int, ok bool) {
	insts := p.insts
	n := len(s)
	pc, pos := 0, start
	for {
		in := &insts[pc]
		fail := false
		switch in.op {
		case opChar:
			if pos < n && s[pos] == in.c {
				pos++
				pc++
			} else {
				fail = true
			}
		case opAny:
			if pos < n {
				pos++
				pc++
			} else {
				fail = true
			}
		case opSet:
			if pos < n && in.set.Has(s[pos]) {
				pos++
				pc++
			} else {
				fail = true
			}
		case opBol:
			if pos == 0 {
				pc++
			} else {
				fail = true
			}
		case opEol:
			if pos == n {
				pc++
			} else {
				fail = true
			}
		case opSplit:
			m.stack = append(m.stack, frame{int(in.y), pos, len(m.trail)})
			pc = int(in.x)
		case opJmp:
			pc = int(in.x)
		case opMark:
			m.set(int(in.x), pos)
			pc++
		case opClose:
			g := int(in.x)
			m.set(2*g, m.regs[in.y])
			m.set(2*g+1, pos)
			pc++
		case opEmptyChk:
			if m.regs[in.x] == pos {
				pc = int(in.y)
			} else {
				pc++
			}
		case opMatch:
			m.stack = m.stack[:0]
			return pos, true
		}
		if fail {
			if len(m.stack) == 0 {
				m.unwind(0)
				return 0, false
			}
			f := m.stack[len(m.stack)-1]
			m.stack = m.stack[:len(m.stack)-1]
			m.unwind(f.trail)
			pc, pos = f.pc, f.pos
		}
	}
}
