package chip8

import (
	"strings"
	"testing"
)

func run(t *testing.T, romHex string, cycles uint64, sched string) *Machine {
	t.Helper()
	rom, err := ParseHexROM(romHex)
	if err != nil {
		t.Fatal(err)
	}
	ev, err := ParseSchedule(sched)
	if err != nil {
		t.Fatal(err)
	}
	m := New()
	if err := m.LoadROM(rom); err != nil {
		t.Fatal(err)
	}
	m.Run(cycles, ev)
	return m
}

func stateLines(m *Machine) string {
	lines := strings.Split(strings.TrimRight(string(m.Format()), "\n"), "\n")
	return strings.Join(lines[32:], "\n")
}

func TestExample1(t *testing.T) {
	m := run(t, "60ff7001610180141208", 6, "")
	want := "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
	if got := stateLines(m); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestExample2DrawWrap(t *testing.T) {
	m := run(t, "6a3e6b1e6000f029dab5dab5", 5, "")
	rows := strings.Split(string(m.Format()), "\n")
	if rows[0] != ".#............................................................#." ||
		rows[2] != "##............................................................##" ||
		rows[3] != strings.Repeat(".", 64) ||
		rows[30] != "##............................................................##" ||
		rows[31] != ".#............................................................#." {
		t.Errorf("unexpected display:\n%s", strings.Join(rows[:32], "\n"))
	}
	if m.V[0xF] != 0 || m.PC != 0x20a {
		t.Errorf("VF=%d PC=%04x", m.V[0xF], m.PC)
	}
	m = run(t, "6a3e6b1e6000f029dab5dab5", 6, "")
	if m.Display != (Display{}) || m.V[0xF] != 1 || m.PC != 0x20c {
		t.Errorf("second draw: VF=%d PC=%04x", m.V[0xF], m.PC)
	}
}

func TestExample3RandomTimersKeys(t *testing.T) {
	m := run(t, "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a", 14, "9:0300")
	want := "PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00"
	if got := stateLines(m); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestRNGSequence(t *testing.T) {
	s := RNGSeed
	for i, want := range []struct {
		state uint32
		b     byte
	}{{0x0b719151, 0x71}, {0x6f47bdb6, 0x47}, {0x2e1d6ab7, 0x1d}} {
		var b byte
		s, b = NextRNG(s)
		if s != want.state || b != want.b {
			t.Errorf("step %d: got %08x/%02x want %08x/%02x", i, s, b, want.state, want.b)
		}
	}
}

func TestZeroCycles(t *testing.T) {
	m := run(t, "6001", 0, "")
	if m.PC != 0x200 || m.V[0] != 0 {
		t.Error("nothing should execute with N=0")
	}
}

func TestFlagWinsWhenXIsF(t *testing.T) {
	// VF=0xff; VF += VF -> sum 510: result 0xfe then flag 1.
	m := run(t, "6fff8ff4", 2, "")
	if m.V[0xF] != 1 {
		t.Errorf("VF=%02x, want 01", m.V[0xF])
	}
}

func TestSubtractAndShifts(t *testing.T) {
	m := run(t, "60056103"+"8015", 3, "") // 5-3
	if m.V[0] != 2 || m.V[0xF] != 1 {
		t.Errorf("8XY5: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
	m = run(t, "60036105"+"8017", 3, "") // V0 = 5-3? VY-VX = 5-3
	if m.V[0] != 2 || m.V[0xF] != 1 {
		t.Errorf("8XY7: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
	m = run(t, "60038016", 2, "")
	if m.V[0] != 1 || m.V[0xF] != 1 {
		t.Errorf("8XY6: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
	m = run(t, "6081800e", 2, "")
	if m.V[0] != 2 || m.V[0xF] != 1 {
		// 6081 sets V0=0x81; 800e shifts V0: 0x02, flag 1
		t.Errorf("8XYE: V0=%d VF=%d", m.V[0], m.V[0xF])
	}
}

func TestCallReturn(t *testing.T) {
	m := run(t, "2204"+"0000"+"00ee", 1, "")
	if m.SP != 1 || m.PC != 0x204 || m.Stack[0] != 0x202 {
		t.Errorf("after call: SP=%d PC=%04x", m.SP, m.PC)
	}
	m.Run(1, nil)
	if m.SP != 0 || m.PC != 0x202 {
		t.Errorf("after ret: SP=%d PC=%04x", m.SP, m.PC)
	}
}

func TestBCDAndRegisterStore(t *testing.T) {
	// V0=234, I=0x300, BCD, V0..V2 load back
	m := run(t, "60eaa300f033f265", 4, "")
	if m.Mem[0x300] != 2 || m.Mem[0x301] != 3 || m.Mem[0x302] != 4 {
		t.Errorf("BCD wrong: %v", m.Mem[0x300:0x303])
	}
	m.Run(1, nil)
	if m.V[0] != 2 || m.V[1] != 3 || m.V[2] != 4 {
		t.Errorf("FX65 wrong: %v", m.V[:3])
	}
}

func TestMemoryWrapAtFFF(t *testing.T) {
	m := New()
	m.PC = 0xFFF
	m.Mem[0xFFF] = 0x60
	m.Mem[0x000] = 0x7b // 607b: V0 = 0x7b
	m.Run(1, nil)
	if m.V[0] != 0x7b || m.PC != 0x001 {
		t.Errorf("V0=%02x PC=%04x", m.V[0], m.PC)
	}
}

func TestBNNNWrapsAndOddPC(t *testing.T) {
	m := run(t, "6001bfff", 2, "")
	if m.PC != 0x000 {
		t.Errorf("PC=%04x, want 0000", m.PC)
	}
}

func TestKeySkips(t *testing.T) {
	// V0=3; EX9E skips if key 3 down: schedule key 3 at cycle 1.
	m := run(t, "6003e09e6101", 3, "1:0008")
	if m.V[1] != 0 {
		t.Error("EX9E should have skipped")
	}
	m = run(t, "6003e0a16101", 3, "1:0008")
	if m.V[1] != 1 {
		t.Error("EXA1 should not skip while key 3 is down")
	}
}

func TestTimerTick(t *testing.T) {
	// V0=10; DT=V0 at cycle 1; then loop. Ticks after cycles 7, 15.
	m := run(t, "600af0151204", 16, "")
	if m.DT != 8 {
		t.Errorf("DT=%d, want 8", m.DT)
	}
}

func TestStepMatchesRun(t *testing.T) {
	a := run(t, "c0ffc1ff7001", 6, "")
	rom, _ := ParseHexROM("c0ffc1ff7001")
	b := New()
	_ = b.LoadROM(rom)
	for i := 0; i < 6; i++ {
		b.Step()
	}
	if string(a.Format()) != string(b.Format()) {
		t.Error("Step x6 differs from Run(6)")
	}
}
