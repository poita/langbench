package chip8

import (
	"fmt"
	"math/bits"
)

// Machine is the complete CHIP-8 machine state.
type Machine struct {
	Mem     [MemSize]byte
	V       [16]byte
	Stack   [16]uint16
	Display Display
	PC      uint16 // 12-bit program counter
	I       uint16 // index register
	SP      int    // number of stack entries (0..16)
	DT, ST  byte   // delay and sound timers
	Keys    uint16 // currently held keys, bit k = key k
	RNG     uint32 // LCG state
	Cycles  uint64 // cycles completed so far
}

// New returns a machine in its power-on state: the font loaded, PC at 0x200
// and the RNG seeded.
func New() *Machine {
	m := &Machine{PC: ROMBase, RNG: RNGSeed}
	copy(m.Mem[FontBase:], Font[:])
	return m
}

// LoadROM copies rom into memory at 0x200.
func (m *Machine) LoadROM(rom []byte) error {
	if len(rom) > MaxROMSize {
		return fmt.Errorf("chip8: ROM is %d bytes, maximum is %d", len(rom), MaxROMSize)
	}
	copy(m.Mem[ROMBase:], rom)
	return nil
}

// Step executes a single cycle with the current key state.
func (m *Machine) Step() { m.Run(1, nil) }

// Run executes exactly n further cycles. schedule holds key events with
// absolute cycle numbers (counted from the start of the machine); events
// before the current cycle are ignored, since their effect is already in m.Keys.
// Events must be sorted by strictly increasing cycle.
//
// The hot scalars live in local variables for the duration of the loop and
// are written back to the machine when it ends.
func (m *Machine) Run(n uint64, schedule []KeyEvent) {
	mem := &m.Mem
	v := &m.V
	stack := &m.Stack
	disp := &m.Display
	pc, idx, sp := m.PC, m.I, m.SP
	dt, st, keys, rng := m.DT, m.ST, m.Keys, m.RNG

	cycle := m.Cycles
	end := cycle + n
	ev := 0
	for ev < len(schedule) && schedule[ev].Cycle < cycle {
		ev++
	}

	for ; cycle < end; cycle++ {
		if ev < len(schedule) && schedule[ev].Cycle == cycle {
			keys = schedule[ev].Mask
			ev++
		}
		op := uint16(mem[pc])<<8 | uint16(mem[(pc+1)&0xFFF])
		pc = (pc + 2) & 0xFFF
		x := op >> 8 & 0xF
		y := op >> 4 & 0xF
		nn := byte(op)
		nnn := op & 0xFFF

		switch op >> 12 {
		case 0x0:
			switch op {
			case 0x00E0:
				*disp = Display{}
			case 0x00EE:
				if sp > 0 {
					sp--
					pc = stack[sp] & 0xFFF
				}
			}
		case 0x1:
			pc = nnn
		case 0x2:
			if sp < 16 {
				stack[sp] = pc
				sp++
			}
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
				v[0xF] = b2b(vx >= vy)
			case 0x6:
				v[x] = vx >> 1
				v[0xF] = vx & 1
			case 0x7:
				v[x] = vy - vx
				v[0xF] = b2b(vy >= vx)
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
			pc = (nnn + uint16(v[0])) & 0xFFF
		case 0xC:
			var r byte
			rng, r = NextRNG(rng)
			v[x] = r & nn
		case 0xD:
			sx := uint(v[x] & 63)
			sy := int(v[y] & 31)
			var hit byte
			for row := 0; row < int(op&0xF); row++ {
				b := mem[(int(idx)+row)&0xFFF]
				if b == 0 {
					continue
				}
				r := bits.RotateLeft64(uint64(b)<<56, -int(sx))
				w := &disp[(sy+row)&31]
				if *w&r != 0 {
					hit = 1
				}
				*w ^= r
			}
			v[0xF] = hit
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
				idx += uint16(v[x])
			case 0x29:
				idx = FontBase + uint16(v[x]&0xF)*5
			case 0x33:
				val := v[x]
				mem[idx&0xFFF] = val / 100
				mem[(idx+1)&0xFFF] = val / 10 % 10
				mem[(idx+2)&0xFFF] = val % 10
			case 0x55:
				for k := uint16(0); k <= x; k++ {
					mem[(idx+k)&0xFFF] = v[k]
				}
			case 0x65:
				for k := uint16(0); k <= x; k++ {
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

	m.PC, m.I, m.SP = pc, idx, sp
	m.DT, m.ST, m.Keys, m.RNG = dt, st, keys, rng
	m.Cycles = cycle
}

func b2b(c bool) byte {
	if c {
		return 1
	}
	return 0
}
