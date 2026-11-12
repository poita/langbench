package bigint

import (
	"math/rand"
	"testing"
)

func mustParse(t testing.TB, s string) *Int {
	t.Helper()
	x, ok := Parse(s)
	if !ok {
		t.Fatalf("Parse(%q) failed", s)
	}
	return x
}

func TestParseString(t *testing.T) {
	tests := []struct{ in, out string }{
		{"0", "0"}, {"-0", "0"}, {"+5", "5"}, {"007", "7"}, {"-42", "-42"},
		{"1000000000", "1000000000"},
		{"999999999", "999999999"},
		{"123456789012345678901234567890", "123456789012345678901234567890"},
		{"-100000000000000000000", "-100000000000000000000"},
		{"4294967296", "4294967296"},
	}
	for _, tc := range tests {
		if got := mustParse(t, tc.in).String(); got != tc.out {
			t.Errorf("Parse(%q).String() = %q, want %q", tc.in, got, tc.out)
		}
	}
	for _, bad := range []string{"", "+", "-", "1a", "--1", "1.5"} {
		if _, ok := Parse(bad); ok {
			t.Errorf("Parse(%q) should fail", bad)
		}
	}
}

func TestInt64RoundTrip(t *testing.T) {
	for _, v := range []int64{0, 1, -1, 1 << 32, -(1 << 32), 1<<63 - 1, -1 << 63} {
		got, ok := New(v).Int64()
		if !ok || got != v {
			t.Errorf("New(%d).Int64() = %d, %v", v, got, ok)
		}
	}
	if _, ok := New(1<<63 - 1).Add(New(1)).Int64(); ok {
		t.Error("2^63 should not fit in int64")
	}
	if _, ok := New(-1 << 63).Sub(New(1)).Int64(); ok {
		t.Error("-2^63-1 should not fit in int64")
	}
}

func TestArithmeticKnown(t *testing.T) {
	a := mustParse(t, "123456789012345678901234567890")
	b := mustParse(t, "987654321098765432109876543210")
	check := func(name string, got *Int, want string) {
		t.Helper()
		if got.String() != want {
			t.Errorf("%s = %s, want %s", name, got, want)
		}
	}
	check("a+b", a.Add(b), "1111111110111111111011111111100")
	check("a-b", a.Sub(b), "-864197532086419753208641975320")
	check("a*b", a.Mul(b), "121932631137021795226185032733622923332237463801111263526900")
	q, r := b.QuoRem(a)
	check("b/a", q, "8")
	check("b%a", r, "9000000000900000000090")
}

func TestFactorial(t *testing.T) {
	f := New(1)
	for i := int64(1); i <= 30; i++ {
		f = f.Mul(New(i))
	}
	if got, want := f.String(), "265252859812191058636308480000000"; got != want {
		t.Errorf("30! = %s, want %s", got, want)
	}
	// Divide it back down.
	for i := int64(30); i >= 1; i-- {
		q, r := f.QuoRem(New(i))
		if r.Sign() != 0 {
			t.Fatalf("30!/%d has remainder %s", i, r)
		}
		f = q
	}
	if f.String() != "1" {
		t.Errorf("got %s, want 1", f)
	}
}

func TestQuoRemSigns(t *testing.T) {
	tests := []struct{ a, b, q, r int64 }{
		{7, 2, 3, 1}, {-7, 2, -3, -1}, {7, -2, -3, 1}, {-7, -2, 3, -1}, {0, 5, 0, 0},
	}
	for _, tc := range tests {
		q, r := New(tc.a).QuoRem(New(tc.b))
		if q.String() != New(tc.q).String() || r.String() != New(tc.r).String() {
			t.Errorf("%d divmod %d = %s, %s; want %d, %d", tc.a, tc.b, q, r, tc.q, tc.r)
		}
	}
}

func randInt(rng *rand.Rand, limbs int) *Int {
	m := make(nat, limbs)
	for i := range m {
		switch rng.Intn(4) {
		case 0:
			m[i] = 0
		case 1:
			m[i] = 0xFFFFFFFF
		default:
			m[i] = rng.Uint32()
		}
	}
	return make_(rng.Intn(2) == 0, m)
}

// TestDivisionIdentity exercises Algorithm D (including the rare add-back
// step) with limb patterns heavy in 0 and 0xFFFFFFFF.
func TestDivisionIdentity(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 20000; i++ {
		a := randInt(rng, 1+rng.Intn(12))
		b := randInt(rng, 1+rng.Intn(8))
		if b.Sign() == 0 {
			continue
		}
		q, r := a.QuoRem(b)
		if got := q.Mul(b).Add(r); got.Cmp(a) != 0 {
			t.Fatalf("q*b+r != a for a=%s b=%s", a, b)
		}
		if natCmp(r.mag, b.mag) >= 0 {
			t.Fatalf("|r| >= |b| for a=%s b=%s", a, b)
		}
		if r.Sign() != 0 && r.Sign() != a.Sign() {
			t.Fatalf("remainder sign wrong for a=%s b=%s", a, b)
		}
	}
}

func TestRingIdentities(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	for i := 0; i < 2000; i++ {
		a, b, c := randInt(rng, 1+rng.Intn(6)), randInt(rng, 1+rng.Intn(6)), randInt(rng, 1+rng.Intn(6))
		if a.Add(b).Sub(b).Cmp(a) != 0 {
			t.Fatal("(a+b)-b != a")
		}
		if a.Mul(b.Add(c)).Cmp(a.Mul(b).Add(a.Mul(c))) != 0 {
			t.Fatal("distributivity failed")
		}
		s := a.String()
		if back := mustParse(t, s); back.Cmp(a) != 0 {
			t.Fatalf("String/Parse round trip failed for %s", s)
		}
	}
}

func BenchmarkFactorial2000(b *testing.B) {
	for n := 0; n < b.N; n++ {
		f := New(1)
		for i := int64(1); i <= 2000; i++ {
			f = f.Mul(New(i))
		}
		_ = f.String()
	}
}
