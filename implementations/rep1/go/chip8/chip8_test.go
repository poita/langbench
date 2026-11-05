package chip8_test

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/example/chip8"
)

func runInput(t *testing.T, in string) string {
	t.Helper()
	p, err := chip8.ParseInput([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	m, err := p.Run()
	if err != nil {
		t.Fatal(err)
	}
	return string(m.Report())
}

func blank(rows int) string { return strings.Repeat(strings.Repeat(".", 64)+"\n", rows) }

func TestExample1(t *testing.T) {
	got := runInput(t, "60ff7001610180141208\n6\n")
	want := blank(32) + "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestExample2DrawWrapAndCollision(t *testing.T) {
	got := runInput(t, "6a3e6b1e6000f029dab5dab5\n5\n")
	lines := strings.Split(got, "\n")
	top := ".#............................................................#."
	for i, w := range []string{top, top, "##............................................................##"} {
		if lines[i] != w {
			t.Errorf("row %d = %q, want %q", i, lines[i], w)
		}
	}
	if lines[30] != "##............................................................##" || lines[31] != top {
		t.Errorf("bottom rows wrong: %q %q", lines[30], lines[31])
	}
	if lines[32] != "PC=020a I=0050 SP=0 DT=00 ST=00" {
		t.Errorf("state line %q", lines[32])
	}
	got = runInput(t, "6a3e6b1e6000f029dab5dab5\n6\n")
	if !strings.HasPrefix(got, blank(32)+"PC=020c I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01") {
		t.Errorf("collision run:\n%s", got)
	}
}

func TestExample3RandomTimersKeys(t *testing.T) {
	got := runInput(t, "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n")
	want := blank(32) + "PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

// machine returns a machine with the given opcodes loaded at 0x200.
func machine(t testing.TB, ops ...uint16) *chip8.Machine {
	t.Helper()
	var rom []byte
	for _, o := range ops {
		rom = append(rom, byte(o>>8), byte(o))
	}
	m := chip8.New()
	if err := m.LoadROM(rom); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestFlagWinsWhenXIsF(t *testing.T) {
	m := machine(t, 0x6FFF, 0x6001, 0x8F04, 0x6F80, 0x8F6E)
	m.Run(3)
	if m.V[0xF] != 1 {
		t.Errorf("8F04 flag: VF=%d, want 1", m.V[0xF])
	}
	m.Run(2)
	if m.V[0xF] != 1 { // 0x80<<1 overflows, flag 1 wins over result 0
		t.Errorf("8F6E: VF=%d, want 1", m.V[0xF])
	}
}

func TestSubtractAndShifts(t *testing.T) {
	m := machine(t, 0x6005, 0x6103, 0x8015, 0x6005, 0x8017, 0x6003, 0x8006, 0x6081, 0x800E)
	m.Run(3)
	if m.V[0] != 2 || m.V[0xF] != 1 {
		t.Errorf("8015: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
	m.Run(2) // V0=5, V0 = V1-V0 = 3-5 borrows
	if m.V[0] != 0xFE || m.V[0xF] != 0 {
		t.Errorf("8017: V0=%#x VF=%d", m.V[0], m.V[0xF])
	}
	m.Run(2)
	if m.V[0] != 1 || m.V[0xF] != 1 {
		t.Errorf("8006: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
	m.Run(2)
	if m.V[0] != 2 || m.V[0xF] != 1 {
		t.Errorf("800E: V0=%#x VF=%d", m.V[0], m.V[0xF])
	}
}

func TestCallReturnAndFullStack(t *testing.T) {
	m := machine(t, 0x2204, 0x1200, 0x00EE)
	m.Run(1)
	if m.SP != 1 || m.PC != 0x204 {
		t.Fatalf("after call SP=%d PC=%#x", m.SP, m.PC)
	}
	m.Run(1)
	if m.SP != 0 || m.PC != 0x202 {
		t.Fatalf("after return SP=%d PC=%#x", m.SP, m.PC)
	}
	// 16 nested calls, each to the next instruction.
	var ops []uint16
	for i := 0; i < 16; i++ {
		ops = append(ops, 0x2202+uint16(2*i))
	}
	m = machine(t, ops...)
	m.Run(16)
	if m.SP != 16 {
		t.Errorf("SP=%d, want 16", m.SP)
	}
}

func TestBNNNWrapsAndOddPC(t *testing.T) {
	m := machine(t, 0x6001+0x0000, 0xBFFF)
	m.Run(2)
	if m.PC != 0x000 {
		t.Errorf("PC=%#x, want 0", m.PC)
	}
}

func TestFetchWrapAtFFF(t *testing.T) {
	m := chip8.New()
	m.Mem[0xFFF] = 0x60 // 6000|NN where NN = mem[0] = 0
	m.Mem[0x000] = 0x2A
	m.PC = 0xFFF
	m.Run(1)
	if m.V[0] != 0x2A || m.PC != 0x001 {
		t.Errorf("V0=%#x PC=%#x", m.V[0], m.PC)
	}
}

func TestMemoryOps(t *testing.T) {
	// V0=234, I=0xFFF, BCD wraps to 0x000/0x001, then store/load V0..V2.
	m := machine(t, 0x60EA, 0xAFFF, 0xF033, 0x6101, 0x6202, 0xF255, 0xF065)
	m.Run(3)
	if m.Mem[0xFFF] != 2 || m.Mem[0] != 3 || m.Mem[1] != 4 {
		t.Errorf("BCD memory: %d %d %d", m.Mem[0xFFF], m.Mem[0], m.Mem[1])
	}
	m.Run(4) // FX55 stores V0..V2 across the wrap, FX65 loads V0 back
	if m.Mem[0xFFF] != 0xEA || m.Mem[0] != 1 || m.Mem[1] != 2 || m.V[0] != 0xEA {
		t.Errorf("FX55/FX65: %d %d %d V0=%d", m.Mem[0xFFF], m.Mem[0], m.Mem[1], m.V[0])
	}
	if m.I != 0xFFF {
		t.Errorf("I=%#x changed", m.I)
	}
}

func TestFX1EAndFX29(t *testing.T) {
	m := machine(t, 0xAFFF, 0x60FF, 0xF01E)
	m.Run(3)
	if m.I != 0x10FE {
		t.Errorf("I=%#x, want 0x10fe", m.I)
	}
	m = machine(t, 0x60FF, 0xF01E)
	m.I = 0xFFFF
	m.Run(2)
	if m.I != 0x00FE {
		t.Errorf("I=%#x, want 0xfe", m.I)
	}
	m = machine(t, 0x601F, 0xF029)
	m.Run(2)
	if m.I != 0x050+15*5 {
		t.Errorf("FX29: I=%#x", m.I)
	}
}

func TestKeySkipsAndSchedule(t *testing.T) {
	m := machine(t, 0x6003, 0xE09E, 0x6101, 0x6201)
	m.RunSchedule(4, []chip8.KeyEvent{{Cycle: 1, Mask: 1 << 3}})
	if m.V[1] != 0 || m.V[2] != 1 {
		t.Errorf("EX9E did not skip: V1=%d V2=%d", m.V[1], m.V[2])
	}
	// An event at cycle N never has an effect on registers.
	m = machine(t, 0x6003, 0xE09E, 0x6101)
	m.RunSchedule(2, []chip8.KeyEvent{{Cycle: 2, Mask: 1 << 3}})
	if m.PC != 0x204 {
		t.Errorf("PC=%#x", m.PC)
	}
}

func TestTimerTick(t *testing.T) {
	// FX15 in cycle 7 is decremented immediately.
	ops := []uint16{0x6008}
	for i := 0; i < 6; i++ {
		ops = append(ops, 0x6100)
	}
	ops = append(ops, 0xF015, 0xF018)
	m := machine(t, ops...)
	m.Run(8)
	if m.DT != 7 || m.ST != 0 {
		t.Errorf("DT=%d ST=%d, want 7 0", m.DT, m.ST)
	}
	m.Run(8) // ST=8 set in cycle 8, ticks after cycle 15
	if m.DT != 6 || m.ST != 7 {
		t.Errorf("DT=%d ST=%d, want 6 7", m.DT, m.ST)
	}
}

func TestRNG(t *testing.T) {
	m := machine(t, 0xC0FF, 0xC1FF, 0xC200, 0xC3FF)
	m.Run(4)
	if m.V[0] != 0x71 || m.V[1] != 0x47 || m.V[2] != 0 {
		t.Errorf("V=%v", m.V[:4])
	}
	if m.RNG == 0x12345678 {
		t.Error("RNG did not advance")
	}
	if m.V[3] != byte(m.RNG>>16) {
		t.Errorf("V3=%#x", m.V[3])
	}
}

func TestNoOpsLeaveStateAlone(t *testing.T) {
	m := machine(t, 0x0123, 0x5121, 0x8128, 0x9121, 0xE000, 0xF0FF, 0x9120)
	m.V[1], m.V[2] = 5, 5
	m.Run(6)
	if m.PC != 0x20C {
		t.Errorf("PC=%#x, want 0x20c", m.PC)
	}
	m.Run(1) // 9120 with equal registers does not skip
	if m.PC != 0x20E {
		t.Errorf("PC=%#x, want 0x20e", m.PC)
	}
}

func TestDrawCollisionAndZeroRows(t *testing.T) {
	m := machine(t, 0xA300, 0xD001, 0xD001, 0xD000)
	m.Mem[0x300] = 0x81
	m.Run(3)
	if m.V[0xF] != 1 || m.Display.Lit() != 0 {
		t.Errorf("VF=%d lit=%d", m.V[0xF], m.Display.Lit())
	}
	m.Run(1)
	if m.V[0xF] != 0 {
		t.Errorf("N=0 VF=%d", m.V[0xF])
	}
}

func TestDisplayPixelAPI(t *testing.T) {
	var d chip8.Display
	d.Set(63, 31, true)
	d.Set(0, 0, true)
	if !d.Pixel(63, 31) || !d.Pixel(0, 0) || d.Pixel(1, 0) || d.Lit() != 2 {
		t.Error("pixel set/get mismatch")
	}
	d.Clear()
	if d.Lit() != 0 {
		t.Error("Clear left pixels")
	}
}

func TestParseInput(t *testing.T) {
	p, err := chip8.ParseInput([]byte("00e0\n10\n0:0001 5:ffff"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(p.ROM, []byte{0x00, 0xE0}) || p.Cycles != 10 || len(p.Events) != 2 ||
		p.Events[1] != (chip8.KeyEvent{Cycle: 5, Mask: 0xFFFF}) {
		t.Errorf("parsed %+v", p)
	}
	p, err = chip8.ParseInput([]byte("00e0\n10\n\n"))
	if err != nil || len(p.Events) != 0 {
		t.Errorf("empty schedule: %+v %v", p, err)
	}
	for _, bad := range []string{"", "00e0\n", "0\n1\n", "zz\n1\n", "00e0\nx\n", "00e0\n1\n1:0001 1:0002", "00e0\n1\n1:01", "00e0\n4000000001\n"} {
		if _, err := chip8.ParseInput([]byte(bad)); err == nil {
			t.Errorf("input %q: expected error", bad)
		}
	}
	big := hex.EncodeToString(make([]byte, 3585)) + "\n1\n"
	if _, err := chip8.ParseInput([]byte(big)); err == nil {
		t.Error("oversized ROM accepted")
	}
	full := hex.EncodeToString(make([]byte, 3584)) + "\n1\n"
	if p, err := chip8.ParseInput([]byte(full)); err != nil {
		t.Error(err)
	} else if _, err := p.Run(); err != nil {
		t.Error(err)
	}
}

func TestLoadROMTooBig(t *testing.T) {
	if err := chip8.New().LoadROM(make([]byte, chip8.MaxROMSize+1)); err == nil {
		t.Error("expected error")
	}
}

func TestReportFormat(t *testing.T) {
	m := chip8.New()
	m.PC, m.I, m.SP, m.DT, m.ST = 0xABC, 0xFFFF, 16, 0x0A, 0xFF
	m.V[15] = 0x0F
	lines := strings.Split(string(m.Report()), "\n")
	if len(lines) != 35 || lines[34] != "" {
		t.Fatalf("got %d lines", len(lines))
	}
	if lines[32] != "PC=0abc I=ffff SP=16 DT=0a ST=ff" {
		t.Errorf("line 33: %q", lines[32])
	}
	if lines[33] != "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0f" {
		t.Errorf("line 34: %q", lines[33])
	}
}

func BenchmarkRun(b *testing.B) {
	for i := 0; i < b.N; i++ {
		m := machine(b, 0x6001, 0xA050, 0xD015, 0x7001, 0x1202)
		m.Run(1_000_000)
	}
}
