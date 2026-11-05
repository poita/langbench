package chip8

import "math/bits"

// RNGSeed is the initial state of the random number generator.
const RNGSeed = 0x12345678

// Machine is the complete CHIP-8 machine state.
type Machine struct {
	Mem     [4096]byte
	V       [16]byte
	Stack   [16]uint16
	Display Display
	PC      uint16 // 12-bit program counter
	I       uint16 // index register (full 16 bits kept)
	SP      int    // number of stack entries
	DT, ST  byte   // delay and sound timers
	Keys    uint16 // currently held keys, bit k = key k
	RNG     uint32 // LCG state
	Cycles  uint64 // cycles completed so far
}

// New returns a machine in its power-on state with the font loaded.
func New() *Machine {
	m := &Machine{PC: ProgramStart, RNG: RNGSeed}
	copy(m.Mem[FontBase:], Font[:])
	return m
}

// LoadROM copies rom into memory at 0x200. Bytes that would not fit are ignored.
func (m *Machine) LoadROM(rom []byte) {
	copy(m.Mem[ProgramStart:], rom)
}

// Run executes n more instruction cycles. events give key-state changes keyed
// by absolute cycle number (counting from the first cycle ever run by this
// machine); events before the current cycle are applied in order first so that
// the key state is correct when resuming.
//
// The whole fetch-decode-execute loop lives here with the hot scalars held in
// local variables; they are written back to the Machine afterwards.
func (m *Machine) Run(n uint64, events []KeyEvent) {
	mem := &m.Mem
	v := &m.V
	stack := &m.Stack
	disp := &m.Display
	pc, idx, sp := uint32(m.PC), uint32(m.I), m.SP
	dt, st := m.DT, m.ST
	keys, rng := m.Keys, m.RNG
	cycle := m.Cycles
	end := cycle + n

	ev := 0
	for ev < len(events) && events[ev].Cycle < cycle {
		keys = events[ev].Mask
		ev++
	}

	for ; cycle < end; cycle++ {
		if ev < len(events) && events[ev].Cycle == cycle {
			keys = events[ev].Mask
			ev++
		}
		op := uint32(mem[pc&0xFFF])<<8 | uint32(mem[(pc+1)&0xFFF])
		pc = (pc + 2) & 0xFFF
		x := (op >> 8) & 0xF
		y := (op >> 4) & 0xF
		nn := byte(op)
		nnn := op & 0xFFF

		switch op >> 12 {
		case 0x0:
			switch op {
			case 0x00E0:
				*disp = Display{}
			case 0x00EE:
				sp--
				pc = uint32(stack[sp&15])
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
			switch op & 0xF {
			case 0x0:
				v[x] = v[y]
			case 0x1:
				v[x] |= v[y]
			case 0x2:
				v[x] &= v[y]
			case 0x3:
				v[x] ^= v[y]
			case 0x4:
				sum := uint16(v[x]) + uint16(v[y])
				v[x] = byte(sum)
				v[15] = byte(sum >> 8)
			case 0x5:
				vx, vy := v[x], v[y]
				v[x] = vx - vy
				if vx >= vy {
					v[15] = 1
				} else {
					v[15] = 0
				}
			case 0x6:
				flag := v[x] & 1
				v[x] >>= 1
				v[15] = flag
			case 0x7:
				vx, vy := v[x], v[y]
				v[x] = vy - vx
				if vy >= vx {
					v[15] = 1
				} else {
					v[15] = 0
				}
			case 0xE:
				flag := v[x] >> 7
				v[x] <<= 1
				v[15] = flag
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
			sx := int(v[x] & 63)
			sy := int(v[y] & 31)
			var flag byte
			for row := uint32(0); row < op&0xF; row++ {
				b := mem[(idx+row)&0xFFF]
				if b == 0 {
					continue
				}
				if disp.XORRow(sx, sy+int(row), b) {
					flag = 1
				}
			}
			v[15] = flag
		case 0xE:
			switch nn {
			case 0x9E:
				if (keys>>(v[x]&0xF))&1 != 0 {
					pc = (pc + 2) & 0xFFF
				}
			case 0xA1:
				if (keys>>(v[x]&0xF))&1 == 0 {
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
				mem[(idx+1)&0xFFF] = (vx / 10) % 10
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
