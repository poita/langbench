// Package chip8 implements a deterministic CHIP-8 interpreter.
//
// A Machine holds the complete CPU state. Load a ROM with New, optionally
// drive it with a KeySchedule, and execute cycles with Step or Run. Every
// cycle fetches and decodes the opcode from memory, so self-modifying
// programs behave correctly.
package chip8

import (
	"errors"
	"fmt"
	"strings"
)

// StackDepth is the number of return addresses the call stack can hold.
const StackDepth = 16

// ErrROMTooLarge is returned by New when the ROM does not fit in memory.
var ErrROMTooLarge = errors.New("chip8: ROM too large")

// Machine is the complete state of a CHIP-8 interpreter.
// The zero value is not usable; create machines with New.
type Machine struct {
	Mem     [MemorySize]byte
	V       [16]byte
	I       uint16
	PC      uint16 // always masked to 12 bits
	Stack   [StackDepth]uint16
	SP      int // number of entries on the stack, 0..StackDepth
	DT, ST  byte
	Display Display

	keys   uint16 // current key state, bit k = key k down
	cycles uint64 // cycles completed so far
	rng    rng
}

// New returns a machine with the font installed and rom loaded at ROMBase.
func New(rom []byte) (*Machine, error) {
	if len(rom) > MaxROMSize {
		return nil, fmt.Errorf("%w: %d bytes (max %d)", ErrROMTooLarge, len(rom), MaxROMSize)
	}
	m := &Machine{PC: ROMBase, rng: rng{Seed}}
	copy(m.Mem[FontBase:], font[:])
	copy(m.Mem[ROMBase:], rom)
	return m, nil
}

// Cycles returns the number of cycles completed so far.
func (m *Machine) Cycles() uint64 { return m.cycles }

// SetKeys sets the keypad state; bit k set means key k is held down.
func (m *Machine) SetKeys(mask uint16) { m.keys = mask }

// Keys returns the current keypad state.
func (m *Machine) Keys() uint16 { return m.keys }

// Run executes exactly n cycles, applying events from sched (which must be in
// strictly increasing cycle order) as their cycle numbers arrive. Cycle
// numbers in sched count from the start of this call.
func (m *Machine) Run(n uint64, sched KeySchedule) {
	next := 0
	for c := uint64(0); c < n; c++ {
		if next < len(sched) && sched[next].Cycle == c {
			m.keys = sched[next].Mask
			next++
		}
		m.Step()
	}
}

// Step executes a single cycle: fetch, execute, then the timer tick.
func (m *Machine) Step() {
	op := uint16(m.Mem[m.PC])<<8 | uint16(m.Mem[(m.PC+1)&0xFFF])
	m.PC = (m.PC + 2) & 0xFFF
	m.execute(op)
	m.cycles++
	if m.cycles&7 == 0 {
		if m.DT > 0 {
			m.DT--
		}
		if m.ST > 0 {
			m.ST--
		}
	}
}

// StatusLine returns the "PC=... I=... SP=... DT=... ST=..." summary line.
func (m *Machine) StatusLine() string {
	return fmt.Sprintf("PC=%04x I=%04x SP=%d DT=%02x ST=%02x", m.PC, m.I, m.SP, m.DT, m.ST)
}

// RegisterLine returns the "V=.. .. .." register dump line.
func (m *Machine) RegisterLine() string {
	var sb strings.Builder
	sb.WriteString("V=")
	for i, v := range m.V {
		if i > 0 {
			sb.WriteByte(' ')
		}
		fmt.Fprintf(&sb, "%02x", v)
	}
	return sb.String()
}

// Report returns the full 34-line textual state dump: the display, the status
// line and the register line, each newline-terminated.
func (m *Machine) Report() string {
	return m.Display.String() + m.StatusLine() + "\n" + m.RegisterLine() + "\n"
}
