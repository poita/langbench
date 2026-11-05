package chip8

import "fmt"

// Memory and machine geometry constants.
const (
	MemSize     = 4096  // bytes of addressable memory
	ProgramBase = 0x200 // address at which ROMs are loaded
	FontBase    = 0x050 // address of the built-in font
	MaxROMSize  = MemSize - ProgramBase
	StackDepth  = 16
	NumRegs     = 16
	rngSeed     = 0x12345678
)

// font holds the 16 built-in 5-byte glyphs for 0..F.
var font = [80]byte{
	0xF0, 0x90, 0x90, 0x90, 0xF0, 0x20, 0x60, 0x20, 0x20, 0x70,
	0xF0, 0x10, 0xF0, 0x80, 0xF0, 0xF0, 0x10, 0xF0, 0x10, 0xF0,
	0x90, 0x90, 0xF0, 0x10, 0x10, 0xF0, 0x80, 0xF0, 0x10, 0xF0,
	0xF0, 0x80, 0xF0, 0x90, 0xF0, 0xF0, 0x10, 0x20, 0x40, 0x40,
	0xF0, 0x90, 0xF0, 0x90, 0xF0, 0xF0, 0x90, 0xF0, 0x10, 0xF0,
	0xF0, 0x90, 0xF0, 0x90, 0x90, 0xE0, 0x90, 0xE0, 0x90, 0xE0,
	0xF0, 0x80, 0x80, 0x80, 0xF0, 0xE0, 0x90, 0x90, 0x90, 0xE0,
	0xF0, 0x80, 0xF0, 0x80, 0xF0, 0xF0, 0x80, 0xF0, 0x80, 0x80,
}

// Machine is the complete state of a CHIP-8 machine. The zero value is not
// ready for use; create machines with New.
//
// All fields are exported so callers can inspect or prepare state directly.
type Machine struct {
	Mem     [MemSize]byte
	V       [NumRegs]byte
	Stack   [StackDepth]uint16
	Display Display

	PC   uint16 // 12-bit program counter
	I    uint16 // 16-bit index register
	SP   int    // number of entries on the stack (0..16)
	DT   byte   // delay timer
	ST   byte   // sound timer
	Keys uint16 // key state: bit k set means key k is down
	RNG  uint32 // LCG state

	// Cycles is the number of instruction cycles completed so far. It
	// drives the timer tick and the key schedule.
	Cycles uint64
}

// New returns a machine in its power-on state: the font loaded at FontBase,
// PC at ProgramBase, all registers and the display cleared.
func New() *Machine {
	m := &Machine{PC: ProgramBase, RNG: rngSeed}
	copy(m.Mem[FontBase:], font[:])
	return m
}

// LoadROM copies rom into memory at ProgramBase. It fails if the ROM does not
// fit in the remaining 3584 bytes.
func (m *Machine) LoadROM(rom []byte) error {
	if len(rom) > MaxROMSize {
		return fmt.Errorf("chip8: ROM is %d bytes, maximum is %d", len(rom), MaxROMSize)
	}
	copy(m.Mem[ProgramBase:], rom)
	return nil
}

// SetKeys replaces the key state; bit k of mask set means key k is down.
func (m *Machine) SetKeys(mask uint16) { m.Keys = mask }
