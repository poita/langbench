package softfloat

import (
	"math"
	"math/rand"
	"testing"
)

func TestSpecExamples(t *testing.T) {
	tests := []struct {
		op   Op
		a, b uint32
		want uint32
	}{
		{OpAdd, 0x3f800000, 0x3f800000, 0x40000000},
		{OpSub, 0x3f800000, 0x3f800000, 0x00000000},
		{OpMul, 0x40400000, 0xc0400000, 0xc1100000},
		{OpDiv, 0x3f800000, 0x40400000, 0x3eaaaaab},
		{OpSqrt, 0x40000000, 0, 0x3fb504f3},
		{OpAdd, 0x7f800000, 0xff800000, QNaN},
		{OpMul, 0x7f800000, 0, QNaN},
		{OpDiv, 0, 0, QNaN},
		{OpSqrt, 0x80000000, 0, 0x80000000},
		{OpSqrt, 0xbf800000, 0, QNaN},
		{OpMul, 0, 0xbf800000, 0x80000000},
		{OpAdd, 0x80000000, 0x80000000, 0x80000000},
		{OpAdd, 0x80000000, 0, 0},
		{OpDiv, 0xbf800000, 0, 0xff800000},
		{OpAdd, 0x7fc12345, 0x3f800000, QNaN},
		{OpAdd, 0x7f7fffff, 0x73000000, 0x7f800000},
		{OpAdd, 0x7f7fffff, 0x72ffffff, 0x7f7fffff},
		{OpDiv, 1, 0x40000000, 0},
		{OpDiv, 3, 0x40000000, 2},
		{OpAdd, 0x3f800000, 0x33800000, 0x3f800000},
		{OpAdd, 0x3f800001, 0x33800000, 0x3f800002},
		{OpAdd, 0x3f800000, 0x33000000, 0x3f800000},
		{OpMul, 1, 0x3f000000, 0},
		{OpMul, 0x80000001, 0x3f000000, 0x80000000},
		{OpAdd, 0x80000000, 0x3f800000, 0x3f800000},
		{OpSub, 0x80000000, 0, 0x80000000},
		{OpSub, 0x80000000, 0x80000000, 0},
		{OpSqrt, 0x7f800000, 0, 0x7f800000},
		{OpSqrt, 0xff800000, 0, QNaN},
		{OpDiv, 0x80000000, 0x7f800000, 0x80000000},
		{OpMul, 0x007fffff, 0x3f800000, 0x007fffff},
		{OpAdd, 0x007fffff, 0x00000001, 0x00800000},
	}
	for _, tc := range tests {
		if got := Eval(tc.op, tc.a, tc.b); got != tc.want {
			t.Errorf("%v %08x %08x = %08x, want %08x", tc.op, tc.a, tc.b, got, tc.want)
		}
	}
}

func TestClassifiers(t *testing.T) {
	if !IsNaN(0x7f800001) || !IsNaN(0xffffffff) || IsNaN(0x7f800000) || IsNaN(0x7f7fffff) {
		t.Error("IsNaN misclassifies")
	}
	if !IsInf(PosInf) || !IsInf(NegInf) || IsInf(QNaN) {
		t.Error("IsInf misclassifies")
	}
	if !IsZero(0) || !IsZero(0x80000000) || IsZero(1) {
		t.Error("IsZero misclassifies")
	}
}

func TestParseOp(t *testing.T) {
	for o := OpAdd; o <= OpSqrt; o++ {
		got, err := ParseOp(o.String())
		if err != nil || got != o {
			t.Errorf("ParseOp(%q) = %v, %v", o.String(), got, err)
		}
	}
	if _, err := ParseOp("pow"); err == nil {
		t.Error("ParseOp accepted unknown operation")
	}
	if Eval(Op(99), 1, 2) != QNaN {
		t.Error("invalid Op should yield QNaN")
	}
}

func TestIsqrt(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for i := 0; i < 100000; i++ {
		n := r.Uint64() >> uint(r.Intn(64))
		root, rem := isqrt(n)
		if root*root+rem != n || rem > 2*root {
			t.Fatalf("isqrt(%d) = %d rem %d", n, root, rem)
		}
	}
}

func TestRoundPackBoundaries(t *testing.T) {
	cases := []struct {
		m      uint64
		e      int
		sticky bool
		want   uint32
	}{
		{1, -149, false, 1},
		{1, -150, false, 0}, // half of the smallest denormal: tie to even (0)
		{1, -150, true, 1},  // just above the tie
		{3, -150, false, 2}, // 1.5 -> 2
		{1, -400, true, 0},  // far below the grid
		{1<<24 - 1, 104, false, 0x7f7fffff},
		{1 << 24, 104, false, PosInf},
		{1<<24 + 1, 103, false, 0x7f000000},           // tie rounds to even: 2^127
		{1<<25 - 1, 103, false, PosInf},               // rounds up to 2^128
		{0xffffffffffffffff, -190, false, 0x00800000}, // rounds up to 2^-126, the smallest normal
	}
	for _, c := range cases {
		if got := roundPack(0, c.m, c.e, c.sticky); got != c.want {
			t.Errorf("roundPack(%#x, %d, %v) = %08x, want %08x", c.m, c.e, c.sticky, got, c.want)
		}
	}
}

// The tests below use the host's float32 arithmetic purely as an independent
// oracle; the library itself never touches floating point.

func oracle(op Op, a, b uint32) uint32 {
	fa, fb := math.Float32frombits(a), math.Float32frombits(b)
	var r float32
	switch op {
	case OpAdd:
		r = fa + fb
	case OpSub:
		r = fa - fb
	case OpMul:
		r = fa * fb
	case OpDiv:
		r = fa / fb
	case OpSqrt:
		r = float32(math.Sqrt(float64(fa)))
	}
	if r != r {
		return QNaN
	}
	return math.Float32bits(r)
}

// interesting returns a random operand biased towards edge cases.
func interesting(r *rand.Rand) uint32 {
	sign := uint32(r.Intn(2)) << 31
	switch r.Intn(8) {
	case 0:
		return r.Uint32()
	case 1: // denormal
		return sign | r.Uint32()&fracMask
	case 2: // tiny denormal
		return sign | r.Uint32()&0xff
	case 3: // near the extremes of the exponent range
		return sign | uint32(r.Intn(4)+0xfc)<<23&expMask | r.Uint32()&fracMask
	case 4: // small fraction (exact-ish values)
		return sign | uint32(r.Intn(60)+100)<<23 | r.Uint32()&0xf<<19
	case 5: // all-ones / zero fractions
		return sign | uint32(r.Intn(256))<<23 | []uint32{0, fracMask, 1}[r.Intn(3)]
	case 6:
		return []uint32{0, signMask, PosInf, NegInf, QNaN, 0x7f800001}[r.Intn(6)]
	}
	return sign | uint32(r.Intn(254)+1)<<23 | r.Uint32()&fracMask
}

func TestAgainstHardware(t *testing.T) {
	r := rand.New(rand.NewSource(42))
	n := 2000000
	if testing.Short() {
		n = 100000
	}
	for i := 0; i < n; i++ {
		op := Op(r.Intn(5))
		a, b := interesting(r), interesting(r)
		if got, want := Eval(op, a, b), oracle(op, a, b); got != want {
			t.Fatalf("%v %08x %08x = %08x, want %08x", op, a, b, got, want)
		}
	}
}

func TestAddExponentGaps(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for i := 0; i < 500000; i++ {
		a := r.Uint32()&0x807fffff | uint32(r.Intn(254)+1)<<23
		gap := r.Intn(70)
		eb := int(a>>23&0xff) - gap
		if eb < 0 {
			eb = 0
		}
		b := r.Uint32()&0x807fffff | uint32(eb)<<23
		for _, op := range []Op{OpAdd, OpSub} {
			if got, want := Eval(op, a, b), oracle(op, a, b); got != want {
				t.Fatalf("%v %08x %08x = %08x, want %08x", op, a, b, got, want)
			}
			if got, want := Eval(op, b, a), oracle(op, b, a); got != want {
				t.Fatalf("%v %08x %08x = %08x, want %08x", op, b, a, got, want)
			}
		}
	}
}

func TestSqrtExhaustiveExponents(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for be := uint32(0); be < 255; be++ {
		for i := 0; i < 2000; i++ {
			a := be<<23 | r.Uint32()&fracMask
			if got, want := Sqrt(a), oracle(OpSqrt, a, 0); got != want {
				t.Fatalf("sqrt %08x = %08x, want %08x", a, got, want)
			}
		}
	}
}

func TestSubIsAddNeg(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	for i := 0; i < 100000; i++ {
		a, b := interesting(r), interesting(r)
		if Sub(a, b) != Add(a, Neg(b)) {
			t.Fatalf("sub != add neg for %08x %08x", a, b)
		}
	}
}
