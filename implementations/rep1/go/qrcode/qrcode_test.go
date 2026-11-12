package qrcode

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSpecExamples checks the SPEC.md worked examples against testdata/.
func TestSpecExamples(t *testing.T) {
	files, _ := filepath.Glob("testdata/example*.in")
	if len(files) != 3 {
		t.Fatalf("found %d example files, want 3", len(files))
	}
	for _, in := range files {
		t.Run(filepath.Base(in), func(t *testing.T) {
			q, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			f := strings.SplitN(strings.TrimSuffix(string(q), "\n"), " ", 3)
			level := map[string]Level{"L": L, "M": M, "Q": Q, "H": H}[f[0]]
			mask := AutoMask
			if f[1] != "auto" {
				mask = int(f[1][0] - '0')
			}
			sym, err := Encode(f[2], level, mask)
			if err != nil {
				t.Fatal(err)
			}
			got := "version " + string(rune('0'+sym.Version())) + " mask " + string(rune('0'+sym.Mask())) + "\n" + sym.String() + "\n"
			if got != string(want) {
				t.Errorf("got\n%s\nwant\n%s", got, want)
			}
		})
	}
}

func TestSelectMode(t *testing.T) {
	tests := []struct {
		in   string
		want Mode
	}{
		{"0123456789", Numeric},
		{"HELLO WORLD", Alphanumeric},
		{"A1 $%*+-./:", Alphanumeric},
		{"hello", Byte},
		{"héllo", Byte},
		{"12a", Byte},
	}
	for _, tc := range tests {
		if got := SelectMode([]byte(tc.in)); got != tc.want {
			t.Errorf("SelectMode(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func TestDataBits(t *testing.T) {
	for n, want := range map[int]int{1: 4, 2: 7, 3: 10, 4: 14, 5: 17, 6: 20} {
		if got := Numeric.dataBits(n); got != want {
			t.Errorf("numeric %d: %d, want %d", n, got, want)
		}
	}
	if got := Alphanumeric.dataBits(5); got != 28 {
		t.Errorf("alnum 5: %d, want 28", got)
	}
	if got := Byte.dataBits(5); got != 40 {
		t.Errorf("byte 5: %d, want 40", got)
	}
}

func TestCapacities(t *testing.T) {
	data := []struct {
		v     int
		l     Level
		bytes int
	}{{1, L, 19}, {1, M, 16}, {1, Q, 13}, {1, H, 9}, {40, L, 2956}, {40, H, 1276}}
	for _, d := range data {
		if got := dataCodewords(d.v, d.l); got != d.bytes {
			t.Errorf("C(%d,%v) = %d, want %d", d.v, d.l, got, d.bytes)
		}
	}
	// Maximum capacities at version 40.
	for _, c := range []struct {
		m    Mode
		l    Level
		want int
	}{{Numeric, L, 7089}, {Alphanumeric, L, 4296}, {Byte, L, 2953}, {Numeric, H, 3057}, {Alphanumeric, H, 1852}, {Byte, H, 1273}} {
		if v := chooseVersion(c.m, c.want, c.l); v != 40 {
			t.Errorf("%v/%v max %d: version %d, want 40", c.m, c.l, c.want, v)
		}
		if v := chooseVersion(c.m, c.want+1, c.l); v != 0 {
			t.Errorf("%v/%v max+1: version %d, want none", c.m, c.l, v)
		}
	}
}

func TestVersionBoundaries(t *testing.T) {
	// 17 bytes fit v1-L? 4+8+136 = 148 <= 152 yes; 18 bytes need v2.
	cases := []struct {
		n    int
		want int
	}{{17, 1}, {18, 2}}
	for _, c := range cases {
		sym, err := EncodeBytes(bytes.Repeat([]byte("a"), c.n), L, 0)
		if err != nil {
			t.Fatal(err)
		}
		if sym.Version() != c.want {
			t.Errorf("%d bytes: version %d, want %d", c.n, sym.Version(), c.want)
		}
	}
}

func TestTooLong(t *testing.T) {
	if _, err := EncodeBytes(bytes.Repeat([]byte("a"), 2954), L, AutoMask); err != ErrTooLong {
		t.Fatalf("err = %v, want ErrTooLong", err)
	}
}

func TestInvalidArguments(t *testing.T) {
	if _, err := Encode("x", Level(7), 0); err == nil {
		t.Error("expected error for invalid level")
	}
	if _, err := Encode("x", L, 8); err == nil {
		t.Error("expected error for invalid mask")
	}
	if _, err := Encode("x", L, -2); err == nil {
		t.Error("expected error for invalid mask")
	}
}

func TestPaddingHelloWorld(t *testing.T) {
	bb := encodeSegment([]byte("HELLO WORLD"), Alphanumeric, 1)
	got := padDataCodewords(bb, 16)
	want := []byte{32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17}
	if !bytes.Equal(got, want) {
		t.Fatalf("data codewords = %v, want %v", got, want)
	}
	full := addECCAndInterleave(got, 1, M)
	if !bytes.Equal(full[16:], []byte{196, 35, 39, 119, 235, 215, 231, 226, 93, 23}) {
		t.Fatalf("ECC = %v", full[16:])
	}
}

func TestInterleaveLength(t *testing.T) {
	for v := MinVersion; v <= MaxVersion; v++ {
		for l := L; l <= H; l++ {
			data := make([]byte, dataCodewords(v, l))
			if got := len(addECCAndInterleave(data, v, l)); got != totalCodewords(v) {
				t.Fatalf("v%d %v: %d codewords, want %d", v, l, got, totalCodewords(v))
			}
		}
	}
}

func TestFormatBits(t *testing.T) {
	// Well-known value: level M, mask 5 -> 100000011001110.
	if got := formatBitsFor(M, 5); got != 0b100000011001110 {
		t.Errorf("format(M,5) = %015b", got)
	}
}

func TestVersionInfo(t *testing.T) {
	g := newFunctionGrid(7)
	// Version 7 information is 000111110010010100.
	var got uint32
	for i := 17; i >= 0; i-- {
		got <<= 1
		if g.modules[(i/3)*g.n+g.n-11+i%3] {
			got |= 1
		}
	}
	if got != 0b000111110010010100 {
		t.Errorf("version 7 info = %018b", got)
	}
}

func TestFunctionModuleCounts(t *testing.T) {
	// Data modules (non-function) must equal rawModules for every version.
	for v := MinVersion; v <= MaxVersion; v++ {
		g := newFunctionGrid(v)
		free := 0
		for _, f := range g.function {
			if !f {
				free++
			}
		}
		if free != rawModules(v) {
			t.Fatalf("v%d: %d free modules, want %d", v, free, rawModules(v))
		}
	}
}

func TestPenaltyHelloWorld(t *testing.T) {
	want := []int{311, 406, 442, 463, 367, 528, 395, 445}
	data := []byte("HELLO WORLD")
	bb := encodeSegment(data, Alphanumeric, 1)
	cw := addECCAndInterleave(padDataCodewords(bb, 16), 1, M)
	base := newFunctionGrid(1)
	base.placeData(cw)
	for m := 0; m < NumMasks; m++ {
		g := base.clone()
		g.applyMask(m)
		g.drawFormat(M, m)
		if got := g.penalty(); got != want[m] {
			t.Errorf("mask %d penalty = %d, want %d", m, got, want[m])
		}
	}
}

func TestLinePenalty(t *testing.T) {
	parse := func(s string) []bool {
		b := make([]bool, len(s))
		for i := range s {
			b[i] = s[i] == '#'
		}
		return b
	}
	tests := []struct {
		line string
		want int
	}{
		{".#.#.#.#", 0},
		{"#####..", 3},
		{"########", 6},
		{"#.###.#....", 40},
		{"....#.###.#", 40},
		{"....#.###.#....", 80}, // both N3 patterns match; no run reaches 5
	}
	for _, tc := range tests {
		if got := linePenalty(parse(tc.line)); got != tc.want {
			t.Errorf("linePenalty(%q) = %d, want %d", tc.line, got, tc.want)
		}
	}
}

func TestBalancePenalty(t *testing.T) {
	// Version 2 has 625 modules; 375 dark is exactly 60%, which is k = 2.
	g := newGrid(2)
	for i := 0; i < 375; i++ {
		g.modules[i] = true
	}
	if got := g.balancePenalty(); got != 20 {
		t.Errorf("60%% dark: %d, want 20", got)
	}
	// 313 dark of 625 (50.08%): k = 0.
	for i := range g.modules {
		g.modules[i] = i%2 == 0
	}
	if got := g.balancePenalty(); got != 0 {
		t.Errorf("50%% dark: %d, want 0", got)
	}
}

func TestSymbolStructure(t *testing.T) {
	sym, err := Encode("structure", Q, AutoMask)
	if err != nil {
		t.Fatal(err)
	}
	n := sym.Size()
	if n != 4*sym.Version()+17 {
		t.Fatalf("size %d for version %d", n, sym.Version())
	}
	if !sym.Dark(8, n-8) {
		t.Error("dark module missing")
	}
	if sym.Dark(-1, 0) || sym.Dark(0, n) {
		t.Error("out-of-range modules must be light")
	}
	rows := strings.Split(strings.TrimSuffix(sym.String(), "\n"), "\n")
	if len(rows) != n || len(rows[0]) != n {
		t.Errorf("String has %d rows of %d chars", len(rows), len(rows[0]))
	}
	if sym.Level() != Q || sym.Level().String() != "Q" {
		t.Error("level accessor")
	}
}

func TestAutoPicksLowestPenaltyFirst(t *testing.T) {
	sym, err := Encode("HELLO WORLD", M, AutoMask)
	if err != nil {
		t.Fatal(err)
	}
	if sym.Mask() != 0 {
		t.Errorf("mask = %d, want 0", sym.Mask())
	}
}

func TestAllVersionsAllLevelsEncode(t *testing.T) {
	for v := MinVersion; v <= MaxVersion; v++ {
		for l := L; l <= H; l++ {
			n := dataCodewords(v, l) - 4 // bytes; leaves room for header at any width
			if n < 1 {
				n = 1
			}
			sym, err := EncodeBytes(bytes.Repeat([]byte{0xAB}, n), l, AutoMask)
			if err != nil {
				t.Fatalf("v%d %v: %v", v, l, err)
			}
			if sym.Version() < v-1 || sym.Version() > v {
				t.Errorf("v%d %v: got version %d", v, l, sym.Version())
			}
		}
	}
}

func BenchmarkEncodeV40Auto(b *testing.B) {
	data := bytes.Repeat([]byte("a"), 2953)
	for i := 0; i < b.N; i++ {
		if _, err := EncodeBytes(data, L, AutoMask); err != nil {
			b.Fatal(err)
		}
	}
}

func ExampleEncode() {
	sym, err := Encode("01234567", L, AutoMask)
	if err != nil {
		panic(err)
	}
	fmt.Println(sym.Version(), sym.Mask())
	// Output: 1 3
}
