package chip8

import "math/bits"

// KeyEvent sets the 16-bit key state from the given cycle onwards: bit k of
// Mask set means key k is down. The event takes effect immediately before
// cycle number Cycle executes.
type KeyEvent struct {
	Cycle uint64
	Mask  uint16
}

// Run executes n more instruction cycles with the machine's current key
// state, which stays unchanged throughout.
func (m *Machine) Run(n uint64) { m.run(m.Cycles+n, nil) }

// RunSchedule executes cycles until m.Cycles reaches total, applying the key
// events as their cycle numbers are reached. Events must be sorted by
// ascending Cycle; events whose cycle is already in the past are applied
// before the first cycle, so the latest such event wins.
func (m *Machine) RunSchedule(total uint64, events []KeyEvent) { m.run(total, events) }

// Step executes a single cycle.
func (m *Machine) Step() { m.run(m.Cycles+1, nil) }

// run is the interpreter loop. The hot scalars live in local variables for the
// duration of the loop and are written back to the machine afterwards. The
// instruction set is decoded with a single switch on the top nibble.
func (m *Machine) run(end uint64, events []KeyEvent) {
	mem := &m.Mem
	v := &m.V
	stack := &m.Stack
	disp := &m.Display
	pc, idx, sp := uint32(m.PC), uint32(m.I), m.SP
	dt, st := m.DT, m.ST
	keys, rng := m.Keys, m.RNG
	cycle := m.Cycles
	ev := 0

	for ; cycle < end; cycle++ {
		if ev < len(events) && events[ev].Cycle <= cycle {
			for ev < len(events) && events[ev].Cycle <= cycle {
				keys = events[ev].Mask
				ev++
			}
		}

		op := uint32(mem[pc])<<8 | uint32(mem[(pc+1)&0xFFF])
		pc = (pc + 2) & 0xFFF
		x := op >> 8 & 0xF
		y := op >> 4 & 0xF
		nn := byte(op)
		nnn := op & 0xFFF

		switch op >> 12 {
		case 0x0:
			if op == 0x00E0 {
				*disp = Display{}
			} else if op == 0x00EE && sp > 0 {
				sp--
				pc = uint32(stack[sp&15]) & 0xFFF
			}
		case 0x1:
			pc = nnn
		case 0x2:
			stack[sp&15] = uint16(pc)
			sp++
			pc = nnn
		case 0x3:
			if v[x] == nn {
				pc = (pc + 2) & 0xFFF
			}
		case 0x4:
			if v[x] != nn {
				pc = (pc + 2) & 0xFFF
			}
		case 0x5:
			if op&0xF == 0 && v[x] == v[y] {
				pc = (pc + 2) & 0xFFF
			}
		case 0x6:
			v[x] = nn
		case 0x7:
			v[x] += nn
		case 0x8:
			vx, vy := v[x], v[y]
			switch op & 0xF {
			case 0x0:
				v[x] = vy
			case 0x1:
				v[x] = vx | vy
			case 0x2:
				v[x] = vx & vy
			case 0x3:
				v[x] = vx ^ vy
			case 0x4:
				sum := uint16(vx) + uint16(vy)
				v[x] = byte(sum)
				v[0xF] = byte(sum >> 8)
			case 0x5:
				v[x] = vx - vy
				if vx >= vy {
					v[0xF] = 1
				} else {
					v[0xF] = 0
				}
			case 0x6:
				v[x] = vx >> 1
				v[0xF] = vx & 1
			case 0x7:
				v[x] = vy - vx
				if vy >= vx {
					v[0xF] = 1
				} else {
					v[0xF] = 0
				}
			case 0xE:
				v[x] = vx << 1
				v[0xF] = vx >> 7
			}
		case 0x9:
			if op&0xF == 0 && v[x] != v[y] {
				pc = (pc + 2) & 0xFFF
			}
		case 0xA:
			idx = nnn
		case 0xB:
			pc = (nnn + uint32(v[0])) & 0xFFF
		case 0xC:
			rng = rng*1103515245 + 12345
			v[x] = byte(rng>>16) & nn
		case 0xD:
			sx := uint(v[x] & 63)
			sy := uint32(v[y] & 31)
			var flag byte
			for row := uint32(0); row < op&0xF; row++ {
				b := mem[(idx+row)&0xFFF]
				w := bits.RotateLeft64(uint64(b)<<56, -int(sx))
				r := &disp[(sy+row)&31]
				if *r&w != 0 {
					flag = 1
				}
				*r ^= w
			}
			v[0xF] = flag
		case 0xE:
			switch nn {
			case 0x9E:
				if keys>>(v[x]&0xF)&1 != 0 {
					pc = (pc + 2) & 0xFFF
				}
			case 0xA1:
				if keys>>(v[x]&0xF)&1 == 0 {
					pc = (pc + 2) & 0xFFF
				}
			}
		case 0xF:
			switch nn {
			case 0x07:
				v[x] = dt
			case 0x0A:
				if keys != 0 {
					v[x] = byte(bits.TrailingZeros16(keys))
				} else {
					pc = (pc - 2) & 0xFFF
				}
			case 0x15:
				dt = v[x]
			case 0x18:
				st = v[x]
			case 0x1E:
				idx = (idx + uint32(v[x])) & 0xFFFF
			case 0x29:
				idx = FontBase + uint32(v[x]&0xF)*5
			case 0x33:
				vx := v[x]
				mem[idx&0xFFF] = vx / 100
				mem[(idx+1)&0xFFF] = vx / 10 % 10
				mem[(idx+2)&0xFFF] = vx % 10
			case 0x55:
				for k := uint32(0); k <= x; k++ {
					mem[(idx+k)&0xFFF] = v[k]
				}
			case 0x65:
				for k := uint32(0); k <= x; k++ {
					v[k] = mem[(idx+k)&0xFFF]
				}
			}
		}

		if (cycle+1)&7 == 0 {
			if dt > 0 {
				dt--
			}
			if st > 0 {
				st--
			}
		}
	}

	m.PC, m.I, m.SP = uint16(pc), uint16(idx), sp
	m.DT, m.ST = dt, st
	m.Keys, m.RNG = keys, rng
	m.Cycles = cycle
}
