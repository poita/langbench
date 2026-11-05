package qr

import (
	"bytes"
	"strings"
	"testing"
)

const helloM0 = `#######...#.#.#######
#.....#.###...#.....#
#.###.#...#.#.#.###.#
#.###.#...#.#.#.###.#
#.###.#.#.###.#.###.#
#.....#..###..#.....#
#######.#.#.#.#######
.....................
#.#.#.#..#..#...#..#.
.####...#..#....#...#
...#######.#..#.##...
####.#.##..###.#.###.
.#..####.#.#..###.#.#
........#.#...#...#.#
#######.....#..#.##..
#.....#..##...##.#...
#.###.#.##..#.#######
#.###.#...##.#.#...#.
#.###.#.####.###.#..#
#.....#....###...#.##
#######.##.#.###....#
`

const numericL3 = `#######.##..#.#######
#.....#..#..#.#.....#
#.###.#.#.#.#.#.###.#
#.###.#.#..#..#.###.#
#.###.#.###...#.###.#
#.....#.......#.....#
#######.#.#.#.#######
.........##..........
####..#.#.#..#..###.#
####...##...#..#.##..
....######..#####..#.
##..#..##.#.##...#.#.
#..#..##..##.#..#....
........##...#.#....#
#######..##..##.#.##.
#.....#....####...#.#
#.###.#..#.#..#.....#
#.###.#.#....#..#.##.
#.###.#.#..#.#..#.#..
#.....#.##.##.#.##.##
#######.##.##..#...#.
`

func TestGoldenSymbols(t *testing.T) {
	tests := []struct {
		text string
		ecl  ECL
		mask int
		ver  int
		want int // mask expected
		rows string
	}{
		{"HELLO WORLD", M, 0, 1, 0, helloM0},
		{"HELLO WORLD", M, AutoMask, 1, 0, helloM0},
		{"01234567", L, AutoMask, 1, 3, numericL3},
	}
	for _, tc := range tests {
		s, err := EncodeString(tc.text, tc.ecl, tc.mask)
		if err != nil {
			t.Fatal(err)
		}
		if s.Version != tc.ver || s.Mask != tc.want || s.String() != tc.rows {
			t.Errorf("%q %v %d: got version %d mask %d\n%s", tc.text, tc.ecl, tc.mask, s.Version, s.Mask, s)
		}
	}
	s, err := EncodeString("héllo", H, 5)
	if err != nil || s.Version != 1 || s.Mask != 5 || s.Mode != Byte {
		t.Fatalf("héllo: %v %+v", err, s)
	}
	if got := strings.Split(s.String(), "\n")[0]; got != "#######.####..#######" {
		t.Errorf("first row %q", got)
	}
}

func TestPenaltiesHelloWorld(t *testing.T) {
	cw := addECCAndInterleave(buildDataCodewords([]byte("HELLO WORLD"), Alphanumeric, 1, M), 1, M)
	b := newBase(1, cw)
	want := []int{311, 406, 442, 463, 367, 528, 395, 445}
	g := newGrid(b.n)
	for m, w := range want {
		b.render(&g, M, m)
		if got := penalty(&g); got != w {
			t.Errorf("mask %d: penalty %d, want %d", m, got, w)
		}
	}
}

func TestDataCodewordsHelloWorld(t *testing.T) {
	data := buildDataCodewords([]byte("HELLO WORLD"), Alphanumeric, 1, M)
	want := []byte{32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17}
	if !bytes.Equal(data, want) {
		t.Fatalf("data %v", data)
	}
	all := addECCAndInterleave(data, 1, M)
	wantECC := []byte{196, 35, 39, 119, 235, 215, 231, 226, 93, 23}
	if !bytes.Equal(all[16:], wantECC) {
		t.Fatalf("ecc %v", all[16:])
	}
}

func TestGF(t *testing.T) {
	if gfExp[8] != 0x1D {
		t.Errorf("2^8 = %#x", gfExp[8])
	}
	for a := 1; a < 256; a++ {
		if gfMul(byte(a), gfExp[255-int(gfLog[a])]) != 1 {
			t.Fatalf("no inverse for %d", a)
		}
	}
	if gfMul(0, 7) != 0 || gfMul(7, 0) != 0 {
		t.Error("zero product")
	}
	// Compare with carry-less multiplication.
	slow := func(a, b int) byte {
		r := 0
		for ; b > 0; b >>= 1 {
			if b&1 != 0 {
				r ^= a
			}
			a <<= 1
			if a&0x100 != 0 {
				a ^= 0x11D
			}
		}
		return byte(r)
	}
	for a := 0; a < 256; a++ {
		for b := 0; b < 256; b++ {
			if gfMul(byte(a), byte(b)) != slow(a, b) {
				t.Fatalf("%d*%d", a, b)
			}
		}
	}
}

func TestRSGenerator(t *testing.T) {
	// x^2 + 3x + 2 = (x+1)(x+2): coefficients without the leading 1.
	if g := rsGenerator(2); !bytes.Equal(g, []byte{3, 2}) {
		t.Errorf("degree 2 generator %v", g)
	}
	// The remainder of a codeword (data || ecc) divided by g must be zero.
	gen := rsGenerator(10)
	data := []byte("some test data!!")
	rem := make([]byte, 10)
	rsRemainder(data, gen, rem)
	rem2 := make([]byte, 10)
	rsRemainder(append(append([]byte{}, data...), rem...), gen, rem2)
	if !bytes.Equal(rem2, make([]byte, 10)) {
		t.Errorf("non-zero syndrome %v", rem2)
	}
}

func TestCapacities(t *testing.T) {
	for _, c := range []struct {
		v   int
		ecl ECL
		n   int
	}{{1, L, 19}, {1, M, 16}, {1, Q, 13}, {1, H, 9}, {40, L, 2956}, {40, H, 1276}} {
		if got := dataCodewords(c.v, c.ecl); got != c.n {
			t.Errorf("C(%d,%v) = %d, want %d", c.v, c.ecl, got, c.n)
		}
	}
	max := func(m Mode, ecl ECL) int {
		n := 0
		for chooseVersion(m, n+1, ecl) != 0 {
			n++
		}
		return n
	}
	for _, c := range []struct {
		m    Mode
		ecl  ECL
		want int
	}{{Numeric, L, 7089}, {Alphanumeric, L, 4296}, {Byte, L, 2953}, {Numeric, H, 3057}, {Alphanumeric, H, 1852}, {Byte, H, 1273}} {
		if got := max(c.m, c.ecl); got != c.want {
			t.Errorf("max %v %v = %d, want %d", c.m, c.ecl, got, c.want)
		}
	}
}

func TestSelectMode(t *testing.T) {
	for s, want := range map[string]Mode{
		"0123": Numeric, "01 23": Alphanumeric, "HELLO": Alphanumeric, "$%*+-./:": Alphanumeric,
		"hello": Byte, "é": Byte, "A\x00": Byte,
	} {
		if got := SelectMode([]byte(s)); got != want {
			t.Errorf("%q: %v, want %v", s, got, want)
		}
	}
}

func TestVersionSelectionBoundaries(t *testing.T) {
	// Version 1-L holds 41 numeric digits, 25 alphanumeric, 17 bytes.
	cases := []struct {
		text string
		ver  int
	}{
		{strings.Repeat("1", 41), 1}, {strings.Repeat("1", 42), 2},
		{strings.Repeat("A", 25), 1}, {strings.Repeat("A", 26), 2},
		{strings.Repeat("a", 17), 1}, {strings.Repeat("a", 18), 2},
	}
	for _, c := range cases {
		s, err := EncodeString(c.text, L, AutoMask)
		if err != nil || s.Version != c.ver {
			t.Errorf("%d x %q: %v %v", len(c.text), c.text[:1], s, err)
		}
	}
}

func TestFormatAndVersionBits(t *testing.T) {
	if got := formatInfoBits(M, 0); got != 0x5412 {
		t.Errorf("M/0 format %#x", got)
	}
	for e := L; e <= H; e++ {
		for m := 0; m < 8; m++ {
			if formatInfoBits(e, m) == 0 {
				t.Errorf("zero format bits")
			}
		}
	}
	if got := versionBits(7); got != 0x07C94 {
		t.Errorf("version 7 bits %#x", got)
	}
	if got := versionBits(40); got != 0x28C69 {
		t.Errorf("version 40 bits %#x", got)
	}
}

func TestStructure(t *testing.T) {
	for _, v := range []int{1, 2, 7, 14, 40} {
		n := Size(v)
		cw := make([]byte, totalCodewords(v))
		b := newBase(v, cw)
		free := 0
		for _, f := range b.fn {
			if f == 0 {
				free++
			}
		}
		if free != rawModules(v) {
			t.Errorf("v%d: %d free modules, want %d", v, free, rawModules(v))
		}
		if b.mod[(n-8)*n+8] != 1 {
			t.Errorf("v%d: dark module missing", v)
		}
	}
}

func TestErrors(t *testing.T) {
	if _, err := Encode(nil, L, 0); err != ErrEmpty {
		t.Errorf("empty: %v", err)
	}
	if _, err := Encode([]byte("a"), ECL(9), 0); err != ErrBadECL {
		t.Errorf("ecl: %v", err)
	}
	if _, err := Encode([]byte("a"), L, 8); err != ErrBadMask {
		t.Errorf("mask: %v", err)
	}
	if _, err := Encode(bytes.Repeat([]byte("a"), 2954), L, 0); err != ErrTooLong {
		t.Errorf("long: %v", err)
	}
	if _, err := Encode(bytes.Repeat([]byte("a"), 2953), L, AutoMask); err != nil {
		t.Errorf("max: %v", err)
	}
}

func TestParse(t *testing.T) {
	if e, ok := ParseECL("Q"); !ok || e != Q {
		t.Error("ParseECL Q")
	}
	if _, ok := ParseECL("X"); ok {
		t.Error("ParseECL X")
	}
	if m, err := ParseMask("auto"); err != nil || m != AutoMask {
		t.Error("ParseMask auto")
	}
	if m, err := ParseMask("7"); err != nil || m != 7 {
		t.Error("ParseMask 7")
	}
	if _, err := ParseMask("8"); err == nil {
		t.Error("ParseMask 8")
	}
}

func TestSymbolAccessors(t *testing.T) {
	s, _ := EncodeString("HELLO WORLD", M, 0)
	if s.Size() != 21 || !s.Dark(0, 0) || s.Dark(7, 0) || s.Dark(-1, 0) || s.Dark(21, 0) {
		t.Error("accessors")
	}
}

func BenchmarkV40Auto(b *testing.B) {
	data := bytes.Repeat([]byte("a"), 1000)
	for i := 0; i < b.N; i++ {
		if _, err := Encode(data, L, AutoMask); err != nil {
			b.Fatal(err)
		}
	}
}
