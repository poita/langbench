package bigint

import (
	"math"
	"strings"
	"testing"
)

func mustParse(t *testing.T, s string) *Int {
	t.Helper()
	x, ok := Parse(s)
	if !ok {
		t.Fatalf("Parse(%q) failed", s)
	}
	return x
}

func TestParseStringRoundTrip(t *testing.T) {
	cases := []string{
		"0", "1", "-1", "999999999", "1000000000", "-1000000000",
		"4294967295", "4294967296", "18446744073709551616",
		"-9223372036854775808", "123456789012345678901234567890",
		"1" + strings.Repeat("0", 100),
	}
	for _, c := range cases {
		if got := mustParse(t, c).String(); got != c {
			t.Errorf("round trip %q -> %q", c, got)
		}
	}
	if got := mustParse(t, "+007").String(); got != "7" {
		t.Errorf("+007 -> %q", got)
	}
	if got := mustParse(t, "-0").String(); got != "0" {
		t.Errorf("-0 -> %q", got)
	}
}

func TestParseInvalid(t *testing.T) {
	for _, s := range []string{"", "+", "-", "1a", "1.5", " 1"} {
		if _, ok := Parse(s); ok {
			t.Errorf("Parse(%q) should fail", s)
		}
	}
}

func TestInt64(t *testing.T) {
	for _, v := range []int64{0, 1, -1, math.MaxInt64, math.MinInt64, 1 << 32, -(1 << 32)} {
		x := FromInt64(v)
		got, ok := x.Int64()
		if !ok || got != v {
			t.Errorf("Int64 round trip of %d gave %d, %v", v, got, ok)
		}
	}
	if _, ok := mustParse(t, "9223372036854775808").Int64(); ok {
		t.Error("2^63 should not fit")
	}
	if v, ok := mustParse(t, "-9223372036854775808").Int64(); !ok || v != math.MinInt64 {
		t.Error("-2^63 should fit")
	}
	if _, ok := mustParse(t, "-9223372036854775809").Int64(); ok {
		t.Error("-2^63-1 should not fit")
	}
}

func TestAddSub(t *testing.T) {
	cases := []struct{ a, b, sum, diff string }{
		{"0", "0", "0", "0"},
		{"1", "-1", "0", "2"},
		{"4294967295", "1", "4294967296", "4294967294"},
		{"-4294967296", "1", "-4294967295", "-4294967297"},
		{"18446744073709551616", "-18446744073709551617", "-1", "36893488147419103233"},
		{"-5", "-7", "-12", "2"},
		{"5", "7", "12", "-2"},
		{"9223372036854775807", "1", "9223372036854775808", "9223372036854775806"},
	}
	for _, c := range cases {
		a, b := mustParse(t, c.a), mustParse(t, c.b)
		if got := a.Add(b).String(); got != c.sum {
			t.Errorf("%s + %s = %s, want %s", c.a, c.b, got, c.sum)
		}
		if got := a.Sub(b).String(); got != c.diff {
			t.Errorf("%s - %s = %s, want %s", c.a, c.b, got, c.diff)
		}
	}
}

func TestMul(t *testing.T) {
	cases := []struct{ a, b, want string }{
		{"0", "123", "0"},
		{"-3", "4", "-12"},
		{"-3", "-4", "12"},
		{"4294967296", "4294967296", "18446744073709551616"},
		{"99999999999", "99999999999", "9999999999800000000001"},
		{"340282366920938463463374607431768211456", "-340282366920938463463374607431768211456",
			"-115792089237316195423570985008687907853269984665640564039457584007913129639936"},
	}
	for _, c := range cases {
		if got := mustParse(t, c.a).Mul(mustParse(t, c.b)).String(); got != c.want {
			t.Errorf("%s * %s = %s, want %s", c.a, c.b, got, c.want)
		}
	}
}

func TestCmpNeg(t *testing.T) {
	vals := []string{"-100000000000000000000", "-5", "0", "5", "100000000000000000000"}
	for i, a := range vals {
		for j, b := range vals {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := mustParse(t, a).Cmp(mustParse(t, b)); got != want {
				t.Errorf("Cmp(%s,%s) = %d, want %d", a, b, got, want)
			}
		}
	}
	if got := FromInt64(0).Neg().String(); got != "0" {
		t.Errorf("-0 = %s", got)
	}
	if got := mustParse(t, "12345678901234567890").Neg().String(); got != "-12345678901234567890" {
		t.Errorf("neg = %s", got)
	}
}

func TestQuoRemKnown(t *testing.T) {
	cases := []struct{ a, b, q, r string }{
		{"7", "2", "3", "1"},
		{"-7", "2", "-3", "-1"},
		{"7", "-2", "-3", "1"},
		{"-7", "-2", "3", "-1"},
		{"1", "5", "0", "1"},
		{"-1", "5", "0", "-1"},
		{"18446744073709551616", "4294967296", "4294967296", "0"},
	}
	for _, c := range cases {
		q, r, ok := mustParse(t, c.a).QuoRem(mustParse(t, c.b))
		if !ok || q.String() != c.q || r.String() != c.r {
			t.Errorf("%s / %s = %v r %v, want %s r %s", c.a, c.b, q, r, c.q, c.r)
		}
	}
}

func TestQuoRemZero(t *testing.T) {
	if _, _, ok := FromInt64(5).QuoRem(FromInt64(0)); ok {
		t.Error("division by zero should report !ok")
	}
}

// pseudo-random generator so the test is deterministic.
type lcg uint64

func (l *lcg) next() uint32 {
	*l = *l*6364136223846793005 + 1442695040888963407
	return uint32(*l >> 32)
}

func randInt(r *lcg, maxLimbs int) *Int {
	n := int(r.next())%maxLimbs + 1
	x := FromInt64(0)
	base := FromInt64(1 << 32)
	for i := 0; i < n; i++ {
		var limb uint32
		switch r.next() % 4 { // include awkward limb values
		case 0:
			limb = 0xffffffff
		case 1:
			limb = 0
		default:
			limb = r.next()
		}
		x = x.Mul(base).Add(FromInt64(int64(limb)))
	}
	if r.next()%2 == 0 {
		x = x.Neg()
	}
	return x
}

// TestDivisionIdentity checks a = q*b + r, |r| < |b| and sign rules on many
// random operands (exercising Knuth D including the add-back correction).
func TestDivisionIdentity(t *testing.T) {
	r := lcg(12345)
	for i := 0; i < 3000; i++ {
		a, b := randInt(&r, 12), randInt(&r, 6)
		if b.IsZero() {
			continue
		}
		q, rem, ok := a.QuoRem(b)
		if !ok {
			t.Fatal("unexpected !ok")
		}
		if back := q.Mul(b).Add(rem); back.Cmp(a) != 0 {
			t.Fatalf("q*b+r != a for a=%s b=%s q=%s r=%s", a, b, q, rem)
		}
		abs := func(x *Int) *Int {
			if x.Sign() < 0 {
				return x.Neg()
			}
			return x
		}
		if abs(rem).Cmp(abs(b)) >= 0 {
			t.Fatalf("|r| >= |b| for a=%s b=%s r=%s", a, b, rem)
		}
		if rem.Sign() != 0 && rem.Sign() != a.Sign() {
			t.Fatalf("remainder sign wrong for a=%s b=%s r=%s", a, b, rem)
		}
	}
}

func TestMulDivInverse(t *testing.T) {
	r := lcg(99)
	for i := 0; i < 500; i++ {
		a, b := randInt(&r, 20), randInt(&r, 20)
		if b.IsZero() {
			continue
		}
		q, rem, _ := a.Mul(b).QuoRem(b)
		if q.Cmp(a) != 0 || !rem.IsZero() {
			t.Fatalf("(a*b)/b != a for a=%s b=%s", a, b)
		}
	}
}

func TestFactorial(t *testing.T) {
	f := FromInt64(1)
	for i := int64(2); i <= 30; i++ {
		f = f.Mul(FromInt64(i))
	}
	if got := f.String(); got != "265252859812191058636308480000000" {
		t.Errorf("30! = %s", got)
	}
	// Divide back down to 1.
	for i := int64(30); i >= 2; i-- {
		q, r, _ := f.QuoRem(FromInt64(i))
		if !r.IsZero() {
			t.Fatalf("30!/%d has remainder", i)
		}
		f = q
	}
	if f.String() != "1" {
		t.Errorf("got %s", f)
	}
	big := FromInt64(1)
	for i := int64(2); i <= 2000; i++ {
		big = big.Mul(FromInt64(i))
	}
	if n := len(big.String()); n != 5736 {
		t.Errorf("2000! has %d digits, want 5736", n)
	}
}
