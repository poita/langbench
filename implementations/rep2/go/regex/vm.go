package regex

// frame is a pending alternative: resume at pc with the subject position pos
// after undoing every slot write above trail.
type frame struct {
	pc, pos, trail int
}

// write records the previous value of a slot so a failed path can restore it.
type write struct {
	slot, old int
}

// machine holds the reusable backtracking state. Between runs every slot is -1
// and both stacks are empty.
type machine struct {
	slots []int
	stack []frame
	trail []write
}

func newMachine(p *program) *machine {
	m := &machine{slots: make([]int, p.slots)}
	for i := range m.slots {
		m.slots[i] = -1
	}
	return m
}

func (m *machine) set(slot, v int) {
	m.trail = append(m.trail, write{slot, m.slots[slot]})
	m.slots[slot] = v
}

// unwind undoes slot writes until the trail has length n. The cost is
// proportional to the number of writes undone.
func (m *machine) unwind(n int) {
	for i := len(m.trail) - 1; i >= n; i-- {
		w := m.trail[i]
		m.slots[w.slot] = w.old
	}
	m.trail = m.trail[:n]
}

// run matches the program against s starting exactly at start. On success it
// returns the end of the match and leaves the capture slots populated; the
// caller must call reset when it has read them. On failure all slots are
// already restored.
func run[T ~string | ~[]byte](m *machine, p *program, s T, start int) (end int, ok bool) {
	insts := p.insts
	m.stack = m.stack[:0]
	m.trail = m.trail[:0]
	pc, pos := 0, start
	for {
		in := &insts[pc]
		switch in.op {
		case opChar:
			if pos < len(s) && s[pos] == byte(in.arg) {
				pos++
				pc++
				continue
			}
		case opAny:
			if pos < len(s) {
				pos++
				pc++
				continue
			}
		case opSet:
			if pos < len(s) && p.sets[in.arg].Has(s[pos]) {
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
			if pos == len(s) {
				pc++
				continue
			}
		case opSplit:
			m.stack = append(m.stack, frame{int(in.alt), pos, len(m.trail)})
			pc = int(in.arg)
			continue
		case opJmp:
			pc = int(in.arg)
			continue
		case opSave, opMark:
			m.set(int(in.arg), pos)
			pc++
			continue
		case opEnd:
			g := int(in.arg)
			m.set(capStart(g), m.slots[tmpStart(p.groups, g)])
			m.set(capEnd(g), pos)
			pc++
			continue
		case opCheck:
			if pos == m.slots[in.arg] {
				pc = int(in.alt)
			} else {
				pc++
			}
			continue
		case opMatch:
			return pos, true
		}
		// The current path failed: resume the most recent choice point.
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

// reset restores every slot to unset after a successful run.
func (m *machine) reset() { m.unwind(0) }
