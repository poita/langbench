package bigint

import (
	"errors"
	"math/rand"
	"strings"
	"testing"
)

func mp(t *testing.T, s string) Int {
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
		// Bias towards 0 and 9 digits to provoke carries and add-back steps.
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

func randInt(r *rand.Rand, maxDigits int) Int {
	x := MustParse(randDigits(r, 1+r.Intn(maxDigits)))
	if r.Intn(2) == 0 {
		x = x.Neg()
	}
	return x
}

func TestParseFormat(t *testing.T) {
	cases := map[string]string{
		"0": "0", "-0": "0", "000": "0", "-000": "0", "007": "7", "-000123": "-123",
		"1000000000": "1000000000", "999999999": "999999999",
		"-1000000000000000000":           "-1000000000000000000",
		"123456789012345678901234567890": "123456789012345678901234567890",
	}
	for in, want := range cases {
		if got := mp(t, in).String(); got != want {
			t.Errorf("Parse(%q).String() = %q, want %q", in, got, want)
		}
	}
	var zero Int
	if zero.String() != "0" {
		t.Errorf("zero value prints %q", zero.String())
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"", "-", "+5", "1 2", "1e3", "--1", "0x10", "12a"} {
		if _, err := Parse(s); !errors.Is(err, ErrSyntax) {
			t.Errorf("Parse(%q) error = %v, want ErrSyntax", s, err)
		}
	}
}

func TestFromInt64(t *testing.T) {
	cases := map[int64]string{
		0: "0", 1: "1", -1: "-1", 1 << 62: "4611686018427387904",
		-1 << 63: "-9223372036854775808", 1<<63 - 1: "9223372036854775807",
	}
	for v, want := range cases {
		if got := FromInt64(v).String(); got != want {
			t.Errorf("FromInt64(%d) = %s, want %s", v, got, want)
		}
	}
	if got := FromUint64(1<<64 - 1).String(); got != "18446744073709551615" {
		t.Errorf("FromUint64(max) = %s", got)
	}
}

// Small values are checked against machine arithmetic.
func TestSmallAgainstInt64(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	vals := []int64{0, 1, -1, 2, -2, 7, -7, 999999999, 1000000000, -1000000000, 1000000001}
	for i := 0; i < 300; i++ {
		vals = append(vals, r.Int63n(2_000_000_000_000)-1_000_000_000_000)
	}
	for _, a := range vals {
		for _, b := range vals {
			A, B := FromInt64(a), FromInt64(b)
			check := func(op string, got Int, want int64) {
				if got.String() != FromInt64(want).String() {
					t.Fatalf("%d %s %d = %s, want %d", a, op, b, got, want)
				}
			}
			check("+", A.Add(B), a+b)
			check("-", A.Sub(B), a-b)
			if a > -3_000_000_000 && a < 3_000_000_000 && b > -3_000_000_000 && b < 3_000_000_000 {
				check("*", A.Mul(B), a*b)
			}
			want := 0
			if a < b {
				want = -1
			} else if a > b {
				want = 1
			}
			if A.Cmp(B) != want {
				t.Fatalf("%d cmp %d = %d, want %d", a, b, A.Cmp(B), want)
			}
			if b != 0 {
				q, rem, err := A.QuoRem(B)
				if err != nil {
					t.Fatal(err)
				}
				check("/", q, a/b)
				check("%", rem, a%b)
			}
		}
	}
}

func TestKnownProducts(t *testing.T) {
	a := mp(t, "-123456789012345678901234567890")
	b := mp(t, "987654321098765432109876543210")
	want := "-121932631137021795226185032733622923332237463801111263526900"
	if got := a.Mul(b).String(); got != want {
		t.Errorf("product = %s, want %s", got, want)
	}
	if got := mp(t, "1000000000000000000000000000000").Sub(FromInt64(1)).String(); got != "999999999999999999999999999999" {
		t.Errorf("borrow chain = %s", got)
	}
	if got := mp(t, "99999999999999999999").Add(FromInt64(1)).String(); got != "100000000000000000000" {
		t.Errorf("carry chain = %s", got)
	}
}

func TestSignsAndZero(t *testing.T) {
	zero, five := FromInt64(0), FromInt64(5)
	for name, got := range map[string]Int{
		"-5*0": five.Neg().Mul(zero), "-0+0": mp(t, "-0").Add(zero),
		"5-5": five.Sub(five), "-5+5": five.Neg().Add(five),
	} {
		if got.String() != "0" || got.Sign() != 0 || got.neg {
			t.Errorf("%s = %s (neg=%v), want canonical 0", name, got, got.neg)
		}
	}
	q, r, _ := FromInt64(-1).QuoRem(FromInt64(2))
	if q.neg || r.String() != "-1" || q.String() != "0" {
		t.Errorf("-1 / 2 = %s rem %s", q, r)
	}
	r2, _ := FromInt64(-7).Rem(FromInt64(7))
	if r2.neg || r2.String() != "0" {
		t.Errorf("-7 %% 7 = %s", r2)
	}
	if mp(t, "-0").Cmp(zero) != 0 || mp(t, "007").Cmp(FromInt64(7)) != 0 {
		t.Error("Cmp must ignore negative zero and leading zeros")
	}
}

func TestDivisionSemantics(t *testing.T) {
	cases := []struct{ a, b, q, r int64 }{
		{7, 2, 3, 1}, {-7, 2, -3, -1}, {7, -2, -3, 1}, {-7, -2, 3, -1}, {-1, 3, 0, -1},
	}
	for _, c := range cases {
		q, r, err := FromInt64(c.a).QuoRem(FromInt64(c.b))
		if err != nil || q.String() != FromInt64(c.q).String() || r.String() != FromInt64(c.r).String() {
			t.Errorf("%d divmod %d = %s, %s (%v)", c.a, c.b, q, r, err)
		}
	}
}

func TestDivisionByZero(t *testing.T) {
	for _, a := range []Int{{}, FromInt64(5)} {
		if _, err := a.Quo(Int{}); !errors.Is(err, ErrDivisionByZero) {
			t.Errorf("Quo error = %v", err)
		}
		if _, err := a.Rem(mp(t, "-000")); !errors.Is(err, ErrDivisionByZero) {
			t.Errorf("Rem error = %v", err)
		}
	}
}

// Division is checked through its defining identity on random large values.
func TestDivisionIdentity(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 2000; i++ {
		a := randInt(r, 400)
		b := randInt(r, 1+r.Intn(250))
		q, rem, err := a.QuoRem(b)
		if err != nil {
			t.Fatal(err)
		}
		if got := q.Mul(b).Add(rem); got.Cmp(a) != 0 {
			t.Fatalf("a=%s b=%s: q*b+r = %s", a, b, got)
		}
		if rem.Abs().Cmp(b.Abs()) >= 0 {
			t.Fatalf("a=%s b=%s: |r| >= |b|", a, b)
		}
		if rem.Sign() != 0 && rem.Sign() != a.Sign() {
			t.Fatalf("a=%s b=%s: remainder sign", a, b)
		}
	}
}

// Divisors made of 0 and 999999999 limbs exercise the qhat correction and
// add-back paths of Algorithm D.
func TestDivisionEdgeLimbs(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	limbs := []string{"000000000", "999999999", "500000000", "499999999", "000000001", "999999998"}
	build := func(n int) Int {
		var sb strings.Builder
		sb.WriteString("1")
		for i := 0; i < n; i++ {
			sb.WriteString(limbs[r.Intn(len(limbs))])
		}
		return mp(t, sb.String())
	}
	for i := 0; i < 3000; i++ {
		a, b := build(2+r.Intn(8)), build(1+r.Intn(5))
		q, rem, _ := a.QuoRem(b)
		if q.Mul(b).Add(rem).Cmp(a) != 0 || rem.Cmp(b) >= 0 || rem.Sign() < 0 {
			t.Fatalf("a=%s b=%s q=%s r=%s", a, b, q, rem)
		}
	}
}

func TestRoundTripIdentities(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for i := 0; i < 500; i++ {
		a, b := randInt(r, 300), randInt(r, 300)
		if a.Add(b).Sub(b).Cmp(a) != 0 {
			t.Fatalf("(a+b)-b != a for %s, %s", a, b)
		}
		if a.Mul(b).Cmp(b.Mul(a)) != 0 {
			t.Fatalf("a*b != b*a for %s, %s", a, b)
		}
		if q, _ := a.Mul(b).Quo(b); q.Cmp(a) != 0 {
			t.Fatalf("(a*b)/b != a for %s, %s", a, b)
		}
		c := randInt(r, 100)
		if a.Mul(b.Add(c)).Cmp(a.Mul(b).Add(a.Mul(c))) != 0 {
			t.Fatalf("distributivity fails for %s, %s, %s", a, b, c)
		}
	}
}

func TestPow(t *testing.T) {
	cases := []struct{ a, b, want string }{
		{"2", "10", "1024"}, {"-2", "3", "-8"}, {"-2", "2", "4"}, {"-1", "999", "-1"},
		{"-1", "1000", "1"}, {"0", "0", "1"}, {"0", "5", "0"}, {"5", "0", "1"},
		{"5", "-0", "1"}, {"-0", "-00", "1"}, {"7", "1", "7"}, {"10", "30", "1" + strings.Repeat("0", 30)},
		{"3", "40", "12157665459056928801"}, {"-3", "41", "-36472996377170786403"},
		{"1", "99999999999999999999999999", "1"}, {"-1", "99999999999999999999999999", "-1"},
		{"0", "99999999999999999999999999", "0"},
	}
	for _, c := range cases {
		got, err := mp(t, c.a).Pow(mp(t, c.b))
		if err != nil || got.String() != c.want {
			t.Errorf("%s ^ %s = %s (%v), want %s", c.a, c.b, got, err, c.want)
		}
	}
	if _, err := FromInt64(2).Pow(FromInt64(-1)); !errors.Is(err, ErrNegativeExponent) {
		t.Errorf("negative exponent error = %v", err)
	}
	if _, err := FromInt64(2).Pow(mp(t, strings.Repeat("9", 40))); !errors.Is(err, ErrExponentTooLarge) {
		t.Errorf("huge exponent error = %v", err)
	}
}

func TestPowMatchesRepeatedMul(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	for i := 0; i < 50; i++ {
		a := randInt(r, 60)
		want := FromInt64(1)
		for e := 0; e <= 20; e++ {
			got, err := a.Pow(FromInt64(int64(e)))
			if err != nil || got.Cmp(want) != 0 {
				t.Fatalf("%s ^ %d = %s, want %s", a, e, got, want)
			}
			want = want.Mul(a)
		}
	}
}

func TestAppendTo(t *testing.T) {
	buf := []byte("x=")
	buf = mp(t, "-1000000005").AppendTo(buf)
	if string(buf) != "x=-1000000005" {
		t.Errorf("AppendTo = %q", buf)
	}
}

func TestImmutability(t *testing.T) {
	a, b := mp(t, "123456789012345678901234567890"), mp(t, "987654321")
	as, bs := a.String(), b.String()
	a.Add(b)
	a.Sub(b)
	a.Mul(b)
	a.QuoRem(b)
	a.Pow(FromInt64(3))
	a.Neg()
	if a.String() != as || b.String() != bs {
		t.Error("operands were modified")
	}
}
