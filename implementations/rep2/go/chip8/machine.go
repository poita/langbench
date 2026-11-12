package chip8

import (
	"errors"
	"fmt"
)

// Machine-model constants.
const (
	MemorySize  = 4096
	ProgramAddr = 0x200
	MaxROMSize  = MemorySize - ProgramAddr
	StackDepth  = 16
	NumRegs     = 16

	addrMask = MemorySize - 1

	// TimerPeriod is the number of cycles between timer ticks.
	TimerPeriod = 8
)

// ErrROMTooLarge is returned by LoadROM when the program does not fit.
var ErrROMTooLarge = errors.New("chip8: ROM does not fit in memory")

// Machine is the complete state of a CHIP-8 machine. The zero value is not
// ready for use; create machines with New.
type Machine struct {
	Mem     [MemorySize]byte
	V       [NumRegs]byte
	I       uint16
	PC      uint16 // always kept within 12 bits
	Stack   [StackDepth]uint16
	SP      int // number of entries on the stack, 0..StackDepth
	DT, ST  byte
	Keys    uint16 // bit k set means key k is down
	RNG     RNG
	Display Display

	// Cycles is the number of cycles completed so far.
	Cycles uint64
}

// New returns a machine in its initial state: the font loaded, PC at 0x200,
// the RNG seeded with DefaultSeed and everything else zero.
func New() *Machine {
	m := &Machine{PC: ProgramAddr, RNG: NewRNG(DefaultSeed)}
	copy(m.Mem[FontAddr:], font[:])
	return m
}

// LoadROM copies rom into memory starting at 0x200.
func (m *Machine) LoadROM(rom []byte) error {
	if len(rom) > MaxROMSize {
		return fmt.Errorf("%w: %d bytes, maximum %d", ErrROMTooLarge, len(rom), MaxROMSize)
	}
	copy(m.Mem[ProgramAddr:], rom)
	return nil
}

// Run executes exactly n cycles, applying the events of schedule as their
// cycles arrive. Cycle numbers are those of the machine's own counter, so
// Run is intended to be called once on a fresh machine; events whose cycle
// has already passed are skipped. Events are consumed in order, so the cost
// per cycle is O(1).
func (m *Machine) Run(n uint64, schedule KeySchedule) {
	next := 0
	for next < len(schedule) && schedule[next].Cycle < m.Cycles {
		next++
	}
	for end := m.Cycles + n; m.Cycles < end; {
		for next < len(schedule) && schedule[next].Cycle == m.Cycles {
			m.Keys = schedule[next].Mask
			next++
		}
		m.Step()
	}
}

// Step executes a single cycle: fetch, execute, and timer tick. It does not
// apply any key schedule; set Keys directly or use Run.
func (m *Machine) Step() {
	hi := m.Mem[m.PC&addrMask]
	lo := m.Mem[(m.PC+1)&addrMask]
	m.PC = (m.PC + 2) & addrMask
	m.execute(uint16(hi)<<8 | uint16(lo))

	m.Cycles++
	if m.Cycles%TimerPeriod == 0 {
		if m.DT > 0 {
			m.DT--
		}
		if m.ST > 0 {
			m.ST--
		}
	}
}

// KeyDown reports whether key k (0x0-0xF) is held down.
func (m *Machine) KeyDown(k byte) bool { return m.Keys>>(k&0xF)&1 != 0 }
