package chip8

import (
	"strings"
	"testing"
)

func runHex(t *testing.T, input string) *Machine {
	t.Helper()
	in, err := ParseInputString(input)
	if err != nil {
		t.Fatal(err)
	}
	m := New()
	m.LoadROM(in.ROM)
	m.Run(in.Cycles, in.Events)
	return m
}

func stateLines(m *Machine) (string, string) {
	lines := strings.Split(strings.TrimSuffix(string(m.Render()), "\n"), "\n")
	return lines[32], lines[33]
}

func TestExample1Arithmetic(t *testing.T) {
	m := runHex(t, "60ff7001610180141208\n6\n")
	s, v := stateLines(m)
	if s != "PC=0208 I=0000 SP=0 DT=00 ST=00" {
		t.Errorf("state line: %q", s)
	}
	if v != "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00" {
		t.Errorf("v line: %q", v)
	}
}

func TestExample2DrawWrapAndCollision(t *testing.T) {
	m := runHex(t, "6a3e6b1e6000f029dab5dab5\n5\n")
	lines := strings.Split(string(m.Render()), "\n")
	want := map[int]string{
		0:  ".#............................................................#.",
		1:  ".#............................................................#.",
		2:  "##............................................................##",
		30: "##............................................................##",
		31: ".#............................................................#.",
	}
	for row, w := range want {
		if lines[row] != w {
			t.Errorf("row %d = %q, want %q", row, lines[row], w)
		}
	}
	if m.V[15] != 0 || m.PC != 0x20a {
		t.Errorf("VF=%d PC=%04x", m.V[15], m.PC)
	}
	m = runHex(t, "6a3e6b1e6000f029dab5dab5\n6\n")
	if m.Display != (Display{}) || m.V[15] != 1 || m.PC != 0x20c {
		t.Errorf("second draw: VF=%d PC=%04x", m.V[15], m.PC)
	}
}

func TestExample3RandomTimersKeys(t *testing.T) {
	m := runHex(t, "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n")
	s, v := stateLines(m)
	if s != "PC=021e I=0000 SP=0 DT=07 ST=00" {
		t.Errorf("state line: %q", s)
	}
	if v != "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00" {
		t.Errorf("v line: %q", v)
	}
}

func TestRNGSequence(t *testing.T) {
	m := runHex(t, "c0ffc1ffc2ff\n3\n")
	if m.V[0] != 0x71 || m.V[1] != 0x47 || m.V[2] != 0x1d || m.RNG != 0x2e1d6ab7 {
		t.Errorf("V=%x RNG=%x", m.V[:3], m.RNG)
	}
}

func TestRNGAdvancesWithZeroMask(t *testing.T) {
	m := runHex(t, "c000\n1\n")
	if m.RNG != 0x0b719151 {
		t.Errorf("RNG=%x", m.RNG)
	}
}

func TestZeroCycles(t *testing.T) {
	m := runHex(t, "6001\n0\n")
	if m.PC != 0x200 || m.V[0] != 0 {
		t.Errorf("PC=%x V0=%x", m.PC, m.V[0])
	}
}

func TestFlagWinsWhenXIsF(t *testing.T) {
	// VF = 0xFF; VF += VF -> sum 0x1FE, VF result 0xFE then flag 1.
	m := runHex(t, "6fff8ff4\n2\n")
	if m.V[15] != 1 {
		t.Errorf("VF=%x", m.V[15])
	}
}

func TestSubtractAndShifts(t *testing.T) {
	cases := []struct {
		rom     string
		cycles  string
		v0, vf  byte
		comment string
	}{
		{"60056103" + "8015", "3", 2, 1, "8XY5 no borrow"},
		{"60036105" + "8015", "3", 0xFE, 0, "8XY5 borrow"},
		{"60036105" + "8017", "3", 2, 1, "8XY7"},
		{"6005" + "8006", "2", 2, 1, "8XY6"},
		{"6081" + "800e", "2", 0x02, 1, "8XYE"},
	}
	for _, c := range cases {
		m := runHex(t, c.rom+"\n"+c.cycles+"\n")
		if m.V[0] != c.v0 || m.V[15] != c.vf {
			t.Errorf("%s: V0=%x VF=%x", c.comment, m.V[0], m.V[15])
		}
	}
}

func TestStackCallReturn(t *testing.T) {
	// 0x200: call 0x206; 0x202: jump self; 0x206: 6107; 0x208: ret
	m := runHex(t, "2206"+"1202"+"0000"+"6107"+"00ee\n4\n")
	if m.SP != 0 || m.PC != 0x202 || m.V[1] != 7 {
		t.Errorf("SP=%d PC=%x V1=%x", m.SP, m.PC, m.V[1])
	}
}

func TestFullStack(t *testing.T) {
	// A call to the next instruction, sixteen times.
	rom := ""
	for i := 0; i < 16; i++ {
		rom += "2" + strings.ToLower(hex3(0x202+2*i))
	}
	m := runHex(t, rom+"\n16\n")
	if m.SP != 16 {
		t.Errorf("SP=%d", m.SP)
	}
}

func hex3(v int) string {
	const d = "0123456789abcdef"
	return string([]byte{d[v>>8&0xF], d[v>>4&0xF], d[v&0xF]})
}

func TestBCDAndRegisterStoreLoad(t *testing.T) {
	// V0=254, I=0x300, BCD, V0..V2 = mem[I..], then store back at 0x310.
	m := runHex(t, "60fe"+"a300"+"f033"+"f265"+"\n4\n")
	if m.Mem[0x300] != 2 || m.Mem[0x301] != 5 || m.Mem[0x302] != 4 {
		t.Errorf("BCD %v", m.Mem[0x300:0x303])
	}
	if m.V[0] != 2 || m.V[1] != 5 || m.V[2] != 4 || m.I != 0x300 {
		t.Errorf("V=%v I=%x", m.V[:3], m.I)
	}
}

func TestMemoryWrap(t *testing.T) {
	// I = 0xFFF; V0=1,V1=2; FX55 with X=1 writes mem[0xFFF], mem[0x000].
	m := runHex(t, "6001"+"6102"+"afff"+"f155\n4\n")
	if m.Mem[0xFFF] != 1 || m.Mem[0] != 2 {
		t.Errorf("mem[FFF]=%x mem[0]=%x", m.Mem[0xFFF], m.Mem[0])
	}
}

func TestFetchAcrossTop(t *testing.T) {
	m := New()
	m.PC = 0xFFF
	m.Mem[0xFFF] = 0x12 // jump
	m.Mem[0] = 0x34     // 0x1234
	m.Run(1, nil)
	if m.PC != 0x234 {
		t.Errorf("PC=%x", m.PC)
	}
	m = New()
	m.PC = 0xFFF
	m.Run(1, nil)
	if m.PC != 0x001 {
		t.Errorf("PC=%x", m.PC)
	}
}

func TestBNNNAndOddPC(t *testing.T) {
	m := runHex(t, "6001"+"b300\n2\n")
	if m.PC != 0x301 {
		t.Errorf("PC=%x", m.PC)
	}
}

func TestFX1EKeepsHighBits(t *testing.T) {
	m := runHex(t, "6001"+"afff"+"f01e\n3\n")
	if m.I != 0x1000 {
		t.Errorf("I=%x", m.I)
	}
}

func TestTimerTick(t *testing.T) {
	// V0 = 20; DT = V0; then spin. After 8 cycles in total DT was set in cycle 1.
	m := runHex(t, "6014"+"f015"+"1204\n8\n")
	if m.DT != 19 {
		t.Errorf("DT=%d", m.DT)
	}
	m = runHex(t, "6003"+"f018"+"1204\n24\n")
	if m.ST != 0 {
		t.Errorf("ST=%d", m.ST)
	}
}

func TestKeySkipsAndSchedule(t *testing.T) {
	// V0=5; skip if key 5 down -> skips 6101; then V2=9.
	rom := "6005" + "e09e" + "6101" + "6209"
	m := runHex(t, rom+"\n4\n0:0020\n")
	if m.V[1] != 0 || m.V[2] != 9 {
		t.Errorf("down: V1=%x V2=%x", m.V[1], m.V[2])
	}
	m = runHex(t, rom+"\n4\n")
	if m.V[1] != 1 {
		t.Errorf("up: V1=%x", m.V[1])
	}
	// Event at cycle N never affects anything.
	m = runHex(t, rom+"\n4\n4:ffff\n")
	if m.Keys != 0 {
		t.Errorf("keys=%x", m.Keys)
	}
}

func TestUnknownOpcodesAreNoOps(t *testing.T) {
	m := runHex(t, "5121"+"8128"+"9123"+"e000"+"f0ff"+"0123\n6\n")
	if m.PC != 0x20c {
		t.Errorf("PC=%x", m.PC)
	}
	for i, v := range m.V {
		if v != 0 {
			t.Errorf("V%d=%x", i, v)
		}
	}
}

func TestResumeRun(t *testing.T) {
	a := runHex(t, "60ff7001610180141208\n6\n")
	b := New()
	b.LoadROM([]byte{0x60, 0xff, 0x70, 0x01, 0x61, 0x01, 0x80, 0x14, 0x12, 0x08})
	b.Run(2, nil)
	b.Run(4, nil)
	if *a != *b {
		t.Error("split run differs from single run")
	}
}
