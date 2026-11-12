package chip8

import (
	"errors"
	"strings"
	"testing"
)

// run assembles a program from big-endian opcodes and runs it for n cycles.
func run(t *testing.T, n uint64, sched KeySchedule, ops ...uint16) *Machine {
	t.Helper()
	rom := make([]byte, 0, 2*len(ops))
	for _, op := range ops {
		rom = append(rom, byte(op>>8), byte(op))
	}
	m := New()
	if err := m.LoadROM(rom); err != nil {
		t.Fatal(err)
	}
	m.Run(n, sched)
	return m
}

func TestInitialState(t *testing.T) {
	m := New()
	if m.PC != 0x200 || m.I != 0 || m.SP != 0 || m.RNG.State() != DefaultSeed {
		t.Fatalf("bad initial state: %+v", m)
	}
	if m.Mem[0x50] != 0xF0 || m.Mem[0x9F] != 0x80 || m.Mem[0xA0] != 0 {
		t.Fatal("font not loaded correctly")
	}
}

func TestLoadROMTooLarge(t *testing.T) {
	m := New()
	if err := m.LoadROM(make([]byte, MaxROMSize)); err != nil {
		t.Fatal(err)
	}
	if err := m.LoadROM(make([]byte, MaxROMSize+1)); !errors.Is(err, ErrROMTooLarge) {
		t.Fatalf("got %v, want ErrROMTooLarge", err)
	}
}

func TestRNGSequence(t *testing.T) {
	r := NewRNG(DefaultSeed)
	for i, want := range []struct {
		state uint32
		b     byte
	}{{0x0b719151, 0x71}, {0x6f47bdb6, 0x47}, {0x2e1d6ab7, 0x1d}} {
		if got := r.Byte(); got != want.b || r.State() != want.state {
			t.Fatalf("step %d: byte %#x state %#x, want %#x %#x", i, got, r.State(), want.b, want.state)
		}
	}
}

func TestALU(t *testing.T) {
	tests := []struct {
		name   string
		ops    []uint16
		v0, vf byte
	}{
		{"add carry", []uint16{0x60FF, 0x6102, 0x8014}, 0x01, 1},
		{"add no carry", []uint16{0x6010, 0x6102, 0x8014}, 0x12, 0},
		{"sub no borrow", []uint16{0x6005, 0x6103, 0x8015}, 0x02, 1},
		{"sub equal", []uint16{0x6005, 0x6105, 0x8015}, 0x00, 1},
		{"sub borrow", []uint16{0x6003, 0x6105, 0x8015}, 0xFE, 0},
		{"subn no borrow", []uint16{0x6003, 0x6105, 0x8017}, 0x02, 1},
		{"subn borrow", []uint16{0x6005, 0x6103, 0x8017}, 0xFE, 0},
		{"shr", []uint16{0x6007, 0x61FF, 0x8016}, 0x03, 1},
		{"shl", []uint16{0x6081, 0x6100, 0x801E}, 0x02, 1},
		{"or leaves vf", []uint16{0x6F07, 0x600C, 0x6103, 0x8011}, 0x0F, 7},
		{"and leaves vf", []uint16{0x6F07, 0x600C, 0x6106, 0x8012}, 0x04, 7},
		{"xor leaves vf", []uint16{0x6F07, 0x600C, 0x6106, 0x8013}, 0x0A, 7},
		{"add imm leaves vf", []uint16{0x6F07, 0x60FF, 0x7002}, 0x01, 7},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := run(t, uint64(len(tc.ops)), nil, tc.ops...)
			if m.V[0] != tc.v0 || m.V[0xF] != tc.vf {
				t.Fatalf("V0=%#x VF=%#x, want %#x %#x", m.V[0], m.V[0xF], tc.v0, tc.vf)
			}
		})
	}
}

func TestFlagWinsWhenXIsF(t *testing.T) {
	// VF = 0xFF + 0x01 -> result 0, flag 1; the flag wins.
	m := run(t, 3, nil, 0x6FFF, 0x6101, 0x8F14)
	if m.V[0xF] != 1 {
		t.Fatalf("VF=%#x, want 1", m.V[0xF])
	}
	// Shifting VF in place: flag is the shifted-out bit.
	m = run(t, 2, nil, 0x6F03, 0x8FF6)
	if m.V[0xF] != 1 {
		t.Fatalf("VF=%#x, want 1", m.V[0xF])
	}
}

func TestSkips(t *testing.T) {
	tests := []struct {
		name string
		ops  []uint16
		pc   uint16
	}{
		{"3X taken", []uint16{0x6005, 0x3005}, 0x206},
		{"3X not taken", []uint16{0x6005, 0x3006}, 0x204},
		{"4X taken", []uint16{0x6005, 0x4006}, 0x206},
		{"5XY0 taken", []uint16{0x5010}, 0x204},
		{"5XY1 is nop", []uint16{0x5011}, 0x202},
		{"9XY0 not taken", []uint16{0x9010}, 0x202},
		{"9XY1 is nop", []uint16{0x6001, 0x9011}, 0x204},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := run(t, uint64(len(tc.ops)), nil, tc.ops...)
			if m.PC != tc.pc {
				t.Fatalf("PC=%#x, want %#x", m.PC, tc.pc)
			}
		})
	}
}

func TestCallReturn(t *testing.T) {
	m := run(t, 1, nil, 0x2206, 0x0000, 0x0000, 0x00EE)
	if m.PC != 0x206 || m.SP != 1 || m.Stack[0] != 0x202 {
		t.Fatalf("after call: PC=%#x SP=%d stack0=%#x", m.PC, m.SP, m.Stack[0])
	}
	m = run(t, 2, nil, 0x2204, 0x0000, 0x00EE)
	if m.PC != 0x202 || m.SP != 0 {
		t.Fatalf("after return: PC=%#x SP=%d", m.PC, m.SP)
	}
}

func TestFullStack(t *testing.T) {
	// A chain of 16 nested calls, each to the next instruction.
	ops := make([]uint16, 16)
	for i := range ops {
		ops[i] = 0x2000 | uint16(0x202+2*i)
	}
	m := run(t, 16, nil, ops...)
	if m.SP != 16 {
		t.Fatalf("SP=%d, want 16", m.SP)
	}
}

func TestJumpBNNNAndPCWrap(t *testing.T) {
	m := run(t, 2, nil, 0x6003, 0xBFFE)
	if m.PC != 0x001 {
		t.Fatalf("PC=%#x, want 0x001", m.PC)
	}
	// Fetch at 0xFFF reads the low byte from 0x000.
	m = New()
	m.Mem[0xFFF] = 0x61
	m.Mem[0x000] = 0x2A
	m.PC = 0xFFF
	m.Step()
	if m.V[1] != 0x2A || m.PC != 0x001 {
		t.Fatalf("V1=%#x PC=%#x", m.V[1], m.PC)
	}
}

func TestIndexAndMemory(t *testing.T) {
	// FX1E leaves I above 0xFFF; FX33 wraps addresses.
	m := run(t, 4, nil, 0xAFFF, 0x60FE, 0xF01E, 0xF033)
	if m.I != 0x10FD {
		t.Fatalf("I=%#x, want 0x10fd", m.I)
	}
	if m.Mem[0x0FD] != 2 || m.Mem[0x0FE] != 5 || m.Mem[0x0FF] != 4 {
		t.Fatalf("BCD wrong: %v", m.Mem[0xFD:0x100])
	}
	m = run(t, 5, nil, 0xAFFF, 0x6011, 0x6122, 0x6233, 0xF255)
	if m.Mem[0xFFF] != 0x11 || m.Mem[0] != 0x22 || m.Mem[1] != 0x33 || m.I != 0xFFF {
		t.Fatal("FX55 should wrap and leave I unchanged")
	}
	m.PC = 0x200
	m.Mem[0x200], m.Mem[0x201] = 0xF3, 0x65
	m.Step()
	if m.V[0] != 0x11 || m.V[1] != 0x22 || m.V[2] != 0x33 {
		t.Fatalf("FX65 wrong: %v", m.V)
	}
}

func TestFontPointer(t *testing.T) {
	m := run(t, 2, nil, 0x601A, 0xF029)
	if m.I != FontAddr+0xA*GlyphSize {
		t.Fatalf("I=%#x", m.I)
	}
}

func TestDrawWrapAndCollision(t *testing.T) {
	ops := []uint16{0x6A3E, 0x6B1E, 0x6000, 0xF029, 0xDAB5, 0xDAB5}
	m := run(t, 5, nil, ops...)
	if m.V[0xF] != 0 || !m.Display.Pixel(62, 30) || !m.Display.Pixel(1, 1) || !m.Display.Pixel(0, 2) {
		t.Fatalf("wrapped draw wrong:\n%s", m.Display.String())
	}
	m = run(t, 6, nil, ops...)
	if m.V[0xF] != 1 || strings.Contains(m.Display.String(), "#") {
		t.Fatal("second draw should erase and set VF")
	}
	m = run(t, 2, nil, 0x6001, 0xD000)
	if m.V[0xF] != 0 {
		t.Fatal("N=0 draw must clear VF")
	}
}

func TestClear(t *testing.T) {
	m := run(t, 3, nil, 0xF029, 0xD005, 0x00E0)
	if strings.Contains(m.Display.String(), "#") {
		t.Fatal("display not cleared")
	}
}

func TestKeys(t *testing.T) {
	sched := KeySchedule{{Cycle: 2, Mask: 1 << 5}}
	// cycle 0: V0=5; cycle 1: EX9E not taken; cycle 2: EX9E taken (key pressed).
	m := run(t, 3, sched, 0x6005, 0xE09E, 0xE09E, 0x6101)
	if m.PC != 0x208 {
		t.Fatalf("PC=%#x, want 0x208", m.PC)
	}
	m = run(t, 2, KeySchedule{{Cycle: 3, Mask: 1 << 5}}, 0x6005, 0xE0A1, 0x1000)
	if m.PC != 0x206 {
		t.Fatalf("EXA1 PC=%#x", m.PC)
	}
	// Event at cycle N never has an effect.
	m = run(t, 2, KeySchedule{{Cycle: 2, Mask: 0xFFFF}}, 0x6000, 0x6000)
	if m.Keys != 0 {
		t.Fatal("event at cycle N applied")
	}
}

func TestWaitForKey(t *testing.T) {
	m := run(t, 3, KeySchedule{{Cycle: 2, Mask: 0x0300}}, 0xF00A)
	if m.V[0] != 8 || m.PC != 0x202 {
		t.Fatalf("V0=%d PC=%#x", m.V[0], m.PC)
	}
	m = run(t, 2, nil, 0xF00A)
	if m.PC != 0x200 {
		t.Fatalf("PC=%#x, want 0x200", m.PC)
	}
}

func TestTimers(t *testing.T) {
	// FX15 in cycle 7 is decremented right after.
	ops := []uint16{0x6008, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xF015, 0xF018}
	m := run(t, 8, nil, ops...)
	if m.DT != 7 {
		t.Fatalf("DT=%d, want 7", m.DT)
	}
	m = run(t, 9, nil, ops...)
	if m.ST != 8 || m.DT != 7 {
		t.Fatalf("DT=%d ST=%d", m.DT, m.ST)
	}
	m = run(t, 16, nil, ops...)
	if m.DT != 6 || m.ST != 7 {
		t.Fatalf("DT=%d ST=%d", m.DT, m.ST)
	}
}

func TestUnknownOpcodesAreNops(t *testing.T) {
	m := run(t, 4, nil, 0x0123, 0x8018, 0xE000, 0xF0FF)
	if m.PC != 0x208 || m.V != [16]byte{} || m.I != 0 {
		t.Fatalf("state changed: %+v", m)
	}
}

func TestSelfModifyingCode(t *testing.T) {
	// Store 0x6007 at 0x20A, then execute it: V0 ends up as 7, not 0x60.
	m := run(t, 6, nil, 0x6060, 0x6107, 0xA20A, 0xF155, 0x0000, 0x0000)
	if m.V[0] != 0x07 {
		t.Fatalf("V0=%#x, want 0x07", m.V[0])
	}
}

func TestRunConsumesScheduleInOrder(t *testing.T) {
	m := New()
	m.Run(10, KeySchedule{{0, 1}, {4, 2}, {9, 4}})
	if m.Keys != 4 || m.Cycles != 10 {
		t.Fatalf("keys=%#x cycles=%d", m.Keys, m.Cycles)
	}
}
