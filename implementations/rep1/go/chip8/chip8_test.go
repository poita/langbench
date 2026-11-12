package chip8_test

import (
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/example/chip8"
)

// runHex parses "rom\ncycles\n[schedule]" and returns the final report.
func runHex(t *testing.T, in string) (*chip8.Machine, string) {
	t.Helper()
	p, err := chip8.ParseProgram(strings.NewReader(in))
	if err != nil {
		t.Fatalf("ParseProgram: %v", err)
	}
	m, err := p.Execute()
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	return m, m.Report()
}

func blank() string { return strings.Repeat(strings.Repeat(".", 64)+"\n", 32) }

func TestExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"arithmetic", "60ff7001610180141208\n6\n",
			blank() + "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"},
		{"draw twice", "6a3e6b1e6000f029dab5dab5\n6\n",
			blank() + "PC=020c I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01\n"},
		{"rng timers keys", "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n",
			blank() + "PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, got := runHex(t, tc.in); got != tc.want {
				t.Errorf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestDrawWrap(t *testing.T) {
	m, out := runHex(t, "6a3e6b1e6000f029dab5\n5\n")
	lines := strings.Split(out, "\n")
	for row, want := range map[int]string{
		0:  ".#............................................................#.",
		2:  "##............................................................##",
		30: "##............................................................##",
		31: ".#............................................................#.",
	} {
		if lines[row] != want {
			t.Errorf("row %d = %q, want %q", row, lines[row], want)
		}
	}
	if m.V[0xF] != 0 {
		t.Errorf("VF = %d, want 0", m.V[0xF])
	}
}

func TestRNGSequence(t *testing.T) {
	m, _ := runHex(t, "c0ffc1ffc2ff\n3\n")
	if m.V[0] != 0x71 || m.V[1] != 0x47 || m.V[2] != 0x1d {
		t.Errorf("V0..V2 = %02x %02x %02x, want 71 47 1d", m.V[0], m.V[1], m.V[2])
	}
}

func TestFlagWinsWhenXIsF(t *testing.T) {
	// VF = 0xFF; VF += VF -> flag 1 overwrites the sum.
	m, _ := runHex(t, "6fff8ff4\n2\n")
	if m.V[0xF] != 1 {
		t.Errorf("VF = %02x, want 01", m.V[0xF])
	}
}

func TestALU(t *testing.T) {
	cases := []struct {
		rom      string
		v0, flag byte
	}{
		{"600561038015", 2, 1},    // 8XY5: 5-3
		{"600361058015", 0xfe, 0}, // 8XY5: 3-5 borrows
		{"600561038017", 0xfe, 0}, // 8XY7: 3-5 borrows
		{"600361058017", 2, 1},    // 8XY7: 5-3
		{"600380f6", 1, 1},        // 8XY6
		{"608180fe", 2, 1},        // 8XYE
		{"60ff61028014", 1, 1},    // 8XY4 overflow
	}
	for _, c := range cases {
		m, _ := runHex(t, c.rom+"\n"+strconv.Itoa(len(c.rom)/4)+"\n")
		if m.V[0] != c.v0 || m.V[0xF] != c.flag {
			t.Errorf("%s: V0=%02x VF=%02x, want %02x %02x", c.rom, m.V[0], m.V[0xF], c.v0, c.flag)
		}
	}
}

func TestMemoryWrapAndBCD(t *testing.T) {
	// V0=254; I=0xFFF; FX33 writes mem[FFF], mem[000], mem[001].
	m, _ := runHex(t, "60feaffff033\n3\n")
	if m.Mem[0xFFF] != 2 || m.Mem[0] != 5 || m.Mem[1] != 4 {
		t.Errorf("BCD = %d %d %d, want 2 5 4", m.Mem[0xFFF], m.Mem[0], m.Mem[1])
	}
}

func TestFetchWrapAtTop(t *testing.T) {
	// Jump to 0xFFF: high byte from mem[FFF], low byte from mem[000]; PC -> 001.
	m, err := chip8.New([]byte{0x1f, 0xff})
	if err != nil {
		t.Fatal(err)
	}
	m.Run(2, nil)
	if m.PC != 0x001 {
		t.Errorf("PC = %04x, want 0001", m.PC)
	}
}

func TestCallReturnFullStack(t *testing.T) {
	// Sixteen nested calls, each to the next instruction.
	var rom []byte
	for i := 0; i < 16; i++ {
		addr := 0x202 + 2*i
		rom = append(rom, byte(0x20|addr>>8), byte(addr))
	}
	m, _ := chip8.New(rom)
	m.Run(16, nil)
	if m.SP != 16 {
		t.Fatalf("SP = %d, want 16", m.SP)
	}
	if m.Stack[0] != 0x202 || m.Stack[15] != 0x220 {
		t.Errorf("stack = %x ... %x", m.Stack[0], m.Stack[15])
	}
}

func TestTimerTick(t *testing.T) {
	// V0=20; DT=V0 in cycle 1; one tick after cycle 7 leaves 19.
	m, _ := runHex(t, "6014f0151204\n8\n")
	if m.DT != 19 {
		t.Errorf("DT = %d, want 19", m.DT)
	}
}

func TestWaitForKey(t *testing.T) {
	m, _ := runHex(t, "f00a\n5\n3:0050\n")
	if m.V[0] != 4 {
		t.Errorf("V0 = %d, want lowest key 4", m.V[0])
	}
	if m.PC != 0x204 {
		t.Errorf("PC = %04x, want 0204", m.PC)
	}
}

func TestKeyEventAtN(t *testing.T) {
	m, _ := runHex(t, "f00a\n2\n2:0001\n")
	if m.PC != 0x200 {
		t.Errorf("PC = %04x, want 0200 (event at N has no effect)", m.PC)
	}
}

func TestSelfModifyingCode(t *testing.T) {
	// Write 6107 over the instruction at 0x208 then execute it.
	// A208 sets I; V0=61; V1=07; F155 stores V0,V1; then 0x208 runs.
	rom := "a208" + "6061" + "6107" + "f155" + "0000"
	m, _ := runHex(t, rom+"\n6\n")
	if m.V[1] != 7 {
		t.Errorf("V1 = %d, want 7", m.V[1])
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{"", "6000\n", "zz\n1\n", "6000\nx\n", "6000\n1\n5:0001 4:0001\n", "6000\n1\n5-0001\n"} {
		if _, err := chip8.ParseProgram(strings.NewReader(in)); err == nil {
			t.Errorf("ParseProgram(%q) succeeded, want error", in)
		}
	}
}

func TestROMTooLarge(t *testing.T) {
	_, err := chip8.New(make([]byte, chip8.MaxROMSize+1))
	if !errors.Is(err, chip8.ErrROMTooLarge) {
		t.Errorf("err = %v, want ErrROMTooLarge", err)
	}
	if _, err := chip8.New(make([]byte, chip8.MaxROMSize)); err != nil {
		t.Errorf("max-size ROM rejected: %v", err)
	}
}

func BenchmarkRun(b *testing.B) {
	rom := []byte{0x60, 0x00, 0xf0, 0x29, 0xd0, 0x05, 0x12, 0x00}
	for i := 0; i < b.N; i++ {
		m, _ := chip8.New(rom)
		m.Run(1_000_000, nil)
	}
}
