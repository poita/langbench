package softfloat

import (
	"math"
	"math/rand"
	"testing"
)

// The hardware float32 type is used here purely as a test oracle; the
// library itself never touches floating point.

func canon(f float32) uint32 {
	if f != f {
		return QNaN
	}
	return math.Float32bits(f)
}

func fl(a uint32) float32 { return math.Float32frombits(a) }

func oracle(op Op, a, b uint32) uint32 {
	x, y := fl(a), fl(b)
	switch op {
	case OpAdd:
		return canon(x + y)
	case OpSub:
		return canon(x - y)
	case OpMul:
		return canon(x * y)
	case OpDiv:
		return canon(x / y)
	}
	// float64 sqrt rounded to float32 is correctly rounded for binary32.
	return canon(float32(math.Sqrt(float64(x))))
}

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
		{OpSub, 0x80000000, 0, 0x80000000},
		{OpSub, 0x80000000, 0x80000000, 0},
		{OpAdd, 0x80000000, 0x3f800000, 0x3f800000},
		{OpSqrt, 0x7f800000, 0, 0x7f800000},
		{OpSqrt, 0xff800000, 0, QNaN},
		{OpDiv, 0x80000000, 0x7f800000, 0x80000000},
	}
	for _, tc := range tests {
		if got := Apply(tc.op, tc.a, tc.b); got != tc.want {
			t.Errorf("%v %08x %08x = %08x, want %08x", tc.op, tc.a, tc.b, got, tc.want)
		}
	}
}

// interesting returns a bit pattern biased towards edge cases.
func interesting(r *rand.Rand) uint32 {
	switch r.Intn(8) {
	case 0: // fully random
		return r.Uint32()
	case 1: // denormal
		return r.Uint32()&0x807fffff | 0
	case 2: // denormal with few significant bits
		return r.Uint32()&0x80000000 | uint32(1)<<uint(r.Intn(23)) | uint32(r.Intn(4))
	case 3: // near the extremes of the exponent range
		e := []uint32{0, 1, 2, 253, 254, 255}[r.Intn(6)]
		return r.Uint32()&0x807fffff | e<<23
	case 4: // sparse fractions
		return r.Uint32()&0xff800000 | uint32(r.Intn(3))<<22 | uint32(r.Intn(2))
	case 5: // neighbourhood of 1.0
		return 0x3f800000 - 4 + uint32(r.Intn(9)) | r.Uint32()&0x80000000
	default: // random finite with moderate exponent
		return r.Uint32()&0x807fffff | uint32(100+r.Intn(55))<<23
	}
}

func TestAgainstHardware(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	n := 2000000
	if testing.Short() {
		n = 100000
	}
	for i := 0; i < n; i++ {
		a, b := interesting(r), interesting(r)
		for op := OpAdd; op <= OpSqrt; op++ {
			if got, want := Apply(op, a, b), oracle(op, a, b); got != want {
				t.Fatalf("%v %08x %08x = %08x, want %08x", op, a, b, got, want)
			}
		}
	}
}

func TestSqrtExhaustiveSamples(t *testing.T) {
	// Every 61st pattern covers all exponents and a spread of fractions.
	for a := uint32(0); a < 1<<31; a += 61 {
		if got, want := Sqrt(a), oracle(OpSqrt, a, 0); got != want {
			t.Fatalf("sqrt %08x = %08x, want %08x", a, got, want)
		}
	}
}

func TestExactSquareRoots(t *testing.T) {
	for i := uint32(1); i < 4096; i++ {
		f := math.Float32bits(float32(i))
		sq := Mul(f, f)
		if got, want := Sqrt(sq), math.Float32bits(float32(i)); got != want {
			t.Fatalf("sqrt(%d^2) = %08x, want %08x", i, got, want)
		}
	}
}

func TestIsqrt(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 100000; i++ {
		x := r.Uint64() >> uint(r.Intn(64)+1)
		root, rem := isqrt(x)
		if root*root+rem != x || rem > 2*root {
			t.Fatalf("isqrt(%d) = %d rem %d", x, root, rem)
		}
	}
}

func TestSubMatchesAddNeg(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 100000; i++ {
		a, b := interesting(r), interesting(r)
		if Sub(a, b) != Add(a, Neg(b)) {
			t.Fatalf("sub %08x %08x differs from add of negation", a, b)
		}
	}
}

func TestOpStringParse(t *testing.T) {
	for op := OpAdd; op <= OpSqrt; op++ {
		got, ok := ParseOp(op.String())
		if !ok || got != op {
			t.Errorf("ParseOp(%q) = %v, %v", op.String(), got, ok)
		}
	}
	if _, ok := ParseOp("pow"); ok {
		t.Error("ParseOp accepted unknown op")
	}
}

func BenchmarkMix(b *testing.B) {
	r := rand.New(rand.NewSource(4))
	xs := make([]uint32, 1024)
	for i := range xs {
		xs[i] = interesting(r)
	}
	b.ResetTimer()
	var sink uint32
	for i := 0; i < b.N; i++ {
		x, y := xs[i&1023], xs[(i*7+1)&1023]
		sink ^= Add(x, y) ^ Mul(x, y) ^ Div(x, y) ^ Sqrt(x)
	}
	_ = sink
}
