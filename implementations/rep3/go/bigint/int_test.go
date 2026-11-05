package bigint

import (
	"math/rand"
	"strings"
	"testing"
)

func mustParse(t testing.TB, s string) *Int {
	t.Helper()
	x, err := Parse(s)
	if err != nil {
		t.Fatalf("Parse(%q): %v", s, err)
	}
	return x
}

func randDigits(r *rand.Rand, n int) string {
	var sb strings.Builder
	sb.WriteByte(byte('1' + r.Intn(9)))
	for i := 1; i < n; i++ {
		// Bias towards 0 and 9 to exercise carries and borrows.
		switch r.Intn(4) {
		case 0:
			sb.WriteByte('0')
		case 1:
			sb.WriteByte('9')
		default:
			sb.WriteByte(byte('0' + r.Intn(10)))
		}
	}
	return sb.String()
}

func randInt(t testing.TB, r *rand.Rand, maxDigits int) *Int {
	x := mustParse(t, randDigits(r, 1+r.Intn(maxDigits)))
	if r.Intn(2) == 0 {
		x = x.Neg()
	}
	return x
}

func TestParseString(t *testing.T) {
	tests := []struct{ in, want string }{
		{"0", "0"}, {"-0", "0"}, {"000", "0"}, {"-000", "0"},
		{"007", "7"}, {"-000123", "-123"},
		{"999999999", "999999999"}, {"1000000000", "1000000000"},
		{"1000000000000000000", "1000000000000000000"},
		{"-123456789012345678901234567890", "-123456789012345678901234567890"},
		{"100000000200000000", "100000000200000000"},
	}
	for _, tc := range tests {
		if got := mustParse(t, tc.in).String(); got != tc.want {
			t.Errorf("Parse(%q).String() = %q, want %q", tc.in, got, tc.want)
		}
	}
	for _, bad := range []string{"", "-", "+1", "1 2", "1e5", "--1", "0x1", " 1"} {
		if _, err := Parse(bad); err != ErrSyntax {
			t.Errorf("Parse(%q) error = %v, want ErrSyntax", bad, err)
		}
	}
}

func TestNewInt(t *testing.T) {
	tests := map[int64]string{
		0: "0", 1: "1", -1: "-1", 999999999: "999999999", 1000000000: "1000000000",
		9223372036854775807:  "9223372036854775807",
		-9223372036854775808: "-9223372036854775808",
	}
	for v, want := range tests {
		if got := NewInt(v).String(); got != want {
			t.Errorf("NewInt(%d) = %s, want %s", v, got, want)
		}
	}
}

func TestSmallAgainstMachineArithmetic(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for i := 0; i < 20000; i++ {
		a := r.Int63n(2000000000000) - 1000000000000
		b := r.Int63n(2000000) - 1000000
		if i%7 == 0 {
			b = r.Int63n(21) - 10
		}
		x, y := NewInt(a), NewInt(b)
		check := func(op string, got *Int, want int64) {
			if got.String() != NewInt(want).String() || got.String() != itoa(want) {
				t.Fatalf("%d %s %d = %s, want %d", a, op, b, got, want)
			}
		}
		check("+", x.Add(y), a+b)
		check("-", x.Sub(y), a-b)
		check("*", x.Mul(y), a*b)
		if b != 0 {
			q, rem, err := x.QuoRem(y)
			if err != nil {
				t.Fatal(err)
			}
			check("/", q, a/b)
			check("%", rem, a%b)
		}
		want := 0
		if a < b {
			want = -1
		} else if a > b {
			want = 1
		}
		if got := x.Cmp(y); got != want {
			t.Fatalf("%d cmp %d = %d, want %d", a, b, got, want)
		}
	}
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	var buf []byte
	for v != 0 {
		d := v % 10
		if d < 0 {
			d = -d
		}
		buf = append([]byte{byte('0' + d)}, buf...)
		v /= 10
	}
	if neg {
		buf = append([]byte{'-'}, buf...)
	}
	return string(buf)
}

func TestSpecDivisionExamples(t *testing.T) {
	tests := []struct {
		a, b, q, r string
	}{
		{"7", "2", "3", "1"}, {"-7", "2", "-3", "-1"},
		{"7", "-2", "-3", "1"}, {"-7", "-2", "3", "-1"},
		{"-1", "3", "0", "-1"}, {"-1", "2", "0", "-1"}, {"-7", "7", "-1", "0"},
		{"0", "5", "0", "0"},
	}
	for _, tc := range tests {
		q, r, err := mustParse(t, tc.a).QuoRem(mustParse(t, tc.b))
		if err != nil || q.String() != tc.q || r.String() != tc.r {
			t.Errorf("%s divmod %s = %v, %v (%v), want %s, %s", tc.a, tc.b, q, r, err, tc.q, tc.r)
		}
	}
	if _, _, err := NewInt(5).QuoRem(&Int{}); err != ErrDivByZero {
		t.Errorf("division by zero: err = %v", err)
	}
	if _, err := (&Int{}).Rem(&Int{}); err != ErrDivByZero {
		t.Errorf("0 %% 0: err = %v", err)
	}
}

func TestKnownProducts(t *testing.T) {
	a := mustParse(t, "-123456789012345678901234567890")
	b := mustParse(t, "987654321098765432109876543210")
	want := "-121932631137021795226185032733622923332237463801111263526900"
	if got := a.Mul(b).String(); got != want {
		t.Errorf("product = %s, want %s", got, want)
	}
	big := mustParse(t, "1"+strings.Repeat("0", 30))
	if got := big.Sub(NewInt(1)).String(); got != strings.Repeat("9", 30) {
		t.Errorf("10^30-1 = %s", got)
	}
}

func TestCmpAndNegativeZero(t *testing.T) {
	if mustParse(t, "-0").Cmp(mustParse(t, "0")) != 0 {
		t.Error("-0 != 0")
	}
	if mustParse(t, "007").Cmp(NewInt(7)) != 0 {
		t.Error("007 != 7")
	}
	if NewInt(-3).Cmp(NewInt(-2)) != -1 || NewInt(-2).Cmp(NewInt(-3)) != 1 {
		t.Error("negative ordering wrong")
	}
	if NewInt(-1).Cmp(NewInt(0)) != -1 || NewInt(1).Cmp(NewInt(0)) != 1 {
		t.Error("sign ordering wrong")
	}
	z := NewInt(-5).Mul(&Int{})
	if z.Sign() != 0 || z.String() != "0" {
		t.Errorf("-5*0 = %s", z)
	}
	if s := NewInt(5).Sub(NewInt(5)); s.Sign() != 0 || s.String() != "0" {
		t.Errorf("5-5 = %s", s)
	}
	if s := (&Int{}).Neg(); s.neg {
		t.Error("Neg(0) is negative")
	}
	if s := NewInt(7).Sub(&Int{}); s.String() != "7" {
		t.Errorf("7-0 = %s", s)
	}
}

func TestAddSubIdentities(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 500; i++ {
		a, b := randInt(t, r, 300), randInt(t, r, 300)
		if got := a.Add(b).Sub(b); got.Cmp(a) != 0 {
			t.Fatalf("(a+b)-b != a for %s, %s", a, b)
		}
		if a.Add(b).Cmp(b.Add(a)) != 0 {
			t.Fatal("addition not commutative")
		}
		if a.Sub(b).Cmp(b.Sub(a).Neg()) != 0 {
			t.Fatal("a-b != -(b-a)")
		}
		if a.Sub(a).Sign() != 0 {
			t.Fatal("a-a != 0")
		}
	}
}

func TestMulProperties(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 300; i++ {
		a, b, c := randInt(t, r, 200), randInt(t, r, 200), randInt(t, r, 100)
		if a.Mul(b).Cmp(b.Mul(a)) != 0 {
			t.Fatal("multiplication not commutative")
		}
		if a.Mul(b.Add(c)).Cmp(a.Mul(b).Add(a.Mul(c))) != 0 {
			t.Fatal("multiplication does not distribute")
		}
	}
}

func TestQuoRemInvariants(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for i := 0; i < 3000; i++ {
		a := randInt(t, r, 400)
		b := randInt(t, r, 1+r.Intn(250))
		q, rem, err := a.QuoRem(b)
		if err != nil {
			t.Fatal(err)
		}
		if got := q.Mul(b).Add(rem); got.Cmp(a) != 0 {
			t.Fatalf("q*b+r != a for a=%s b=%s", a, b)
		}
		if rem.Abs().Cmp(b.Abs()) >= 0 {
			t.Fatalf("|r| >= |b| for a=%s b=%s", a, b)
		}
		if rem.Sign() != 0 && rem.Sign() != a.Sign() {
			t.Fatalf("remainder sign wrong for a=%s b=%s", a, b)
		}
	}
}

// TestDivisionEdgeCases targets the rare add-back and qhat-correction paths
// of Algorithm D using limbs near 0 and base-1.
func TestDivisionEdgeCases(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	limbs := []string{"000000000", "999999999", "500000000", "499999999", "000000001", "999999998", "100000000"}
	gen := func(n int) *Int {
		var sb strings.Builder
		sb.WriteString("1")
		for i := 0; i < n; i++ {
			sb.WriteString(limbs[r.Intn(len(limbs))])
		}
		return mustParse(t, sb.String())
	}
	for i := 0; i < 20000; i++ {
		a := gen(2 + r.Intn(8))
		b := gen(1 + r.Intn(4))
		q, rem, _ := a.QuoRem(b)
		if q.Mul(b).Add(rem).Cmp(a) != 0 || rem.Sign() < 0 || rem.Cmp(b) >= 0 {
			t.Fatalf("bad division of %s by %s: q=%s r=%s", a, b, q, rem)
		}
	}
	// Exact divisions and a power of ten.
	p := mustParse(t, "1"+strings.Repeat("0", 99))
	q, rem, _ := p.QuoRem(mustParse(t, "1"+strings.Repeat("0", 40)))
	if q.String() != "1"+strings.Repeat("0", 59) || rem.Sign() != 0 {
		t.Errorf("10^99 / 10^40 = %s r %s", q, rem)
	}
}

func TestPow(t *testing.T) {
	tests := []struct {
		base string
		exp  uint64
		want string
	}{
		{"2", 10, "1024"}, {"-2", 3, "-8"}, {"-2", 2, "4"}, {"-1", 999, "-1"},
		{"0", 0, "1"}, {"0", 5, "0"}, {"7", 0, "1"}, {"-7", 0, "1"}, {"7", 1, "7"},
		{"10", 40, "1" + strings.Repeat("0", 40)},
		{"2", 100, "1267650600228229401496703205376"},
		{"-0", 3, "0"},
	}
	for _, tc := range tests {
		if got := mustParse(t, tc.base).Pow(tc.exp).String(); got != tc.want {
			t.Errorf("%s^%d = %s, want %s", tc.base, tc.exp, got, tc.want)
		}
	}
	// x^(m+n) == x^m * x^n
	r := rand.New(rand.NewSource(6))
	for i := 0; i < 100; i++ {
		x := randInt(t, r, 30)
		m, n := uint64(r.Intn(40)), uint64(r.Intn(40))
		if x.Pow(m+n).Cmp(x.Pow(m).Mul(x.Pow(n))) != 0 {
			t.Fatalf("pow law fails for %s, %d, %d", x, m, n)
		}
	}
}

func TestExp(t *testing.T) {
	zero := &Int{}
	if _, err := NewInt(2).Exp(NewInt(-1)); err != ErrNegativeExponent {
		t.Errorf("2^-1 err = %v", err)
	}
	if z, err := NewInt(5).Exp(mustParse(t, "-0")); err != nil || z.String() != "1" {
		t.Errorf("5^-0 = %v, %v", z, err)
	}
	if z, err := zero.Exp(mustParse(t, "-00")); err != nil || z.String() != "1" {
		t.Errorf("0^-00 = %v, %v", z, err)
	}
	if z, err := NewInt(-3).Exp(NewInt(3)); err != nil || z.String() != "-27" {
		t.Errorf("-3^3 = %v, %v", z, err)
	}
	huge := mustParse(t, "1"+strings.Repeat("0", 50)+"1") // odd, > 2^64
	if z, err := NewInt(-1).Exp(huge); err != nil || z.String() != "-1" {
		t.Errorf("-1^huge = %v, %v", z, err)
	}
	if z, err := NewInt(0).Exp(huge); err != nil || z.String() != "0" {
		t.Errorf("0^huge = %v, %v", z, err)
	}
	if _, err := NewInt(2).Exp(huge); err != ErrExponentTooLarge {
		t.Errorf("2^huge err = %v", err)
	}
}

func TestUint64(t *testing.T) {
	if v, ok := mustParse(t, "18446744073709551615").Uint64(); !ok || v != ^uint64(0) {
		t.Errorf("max uint64: %d %v", v, ok)
	}
	for _, s := range []string{"18446744073709551616", "-1", "1000000000000000000000000000"} {
		if _, ok := mustParse(t, s).Uint64(); ok {
			t.Errorf("Uint64(%s) should not fit", s)
		}
	}
	if v, ok := (&Int{}).Uint64(); !ok || v != 0 {
		t.Error("Uint64(0)")
	}
}

func TestLargeRoundTrip(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	s := randDigits(r, 50000)
	if got := mustParse(t, s).String(); got != s {
		t.Error("50000-digit round trip failed")
	}
	a := mustParse(t, s)
	b := mustParse(t, randDigits(r, 25000))
	q, rem, _ := a.QuoRem(b)
	if q.Mul(b).Add(rem).Cmp(a) != 0 {
		t.Error("large division identity failed")
	}
}

func BenchmarkMul50k(b *testing.B) {
	r := rand.New(rand.NewSource(8))
	x := mustParse(b, randDigits(r, 50000))
	y := mustParse(b, randDigits(r, 50000))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		x.Mul(y)
	}
}
