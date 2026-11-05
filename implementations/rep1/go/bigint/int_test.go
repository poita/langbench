package bigint

import (
	"math/rand"
	"strings"
	"testing"
)

func mustStr(t *testing.T, x *Int, err error) string {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	return x.String()
}

func TestParseAndString(t *testing.T) {
	cases := map[string]string{
		"0": "0", "-0": "0", "000": "0", "-000": "0",
		"007": "7", "-000123": "-123", "123456789": "123456789",
		"1000000000": "1000000000", "-999999999999999999": "-999999999999999999",
		"1000000000000000000": "1000000000000000000",
		"100000000200000000":  "100000000200000000",
	}
	for in, want := range cases {
		x, err := Parse(in)
		if err != nil {
			t.Fatalf("Parse(%q): %v", in, err)
		}
		if got := x.String(); got != want {
			t.Errorf("Parse(%q).String() = %q, want %q", in, got, want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{"", "-", "+1", "1 2", "1e5", "--1", "0x10", "1_000", " 1"} {
		if _, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", in)
		}
	}
}

func TestFromInt64(t *testing.T) {
	cases := map[int64]string{
		0: "0", 1: "1", -1: "-1", 1000000000: "1000000000",
		9223372036854775807:  "9223372036854775807",
		-9223372036854775808: "-9223372036854775808",
	}
	for v, want := range cases {
		if got := FromInt64(v).String(); got != want {
			t.Errorf("FromInt64(%d) = %s, want %s", v, got, want)
		}
	}
	if got := FromUint64(18446744073709551615).String(); got != "18446744073709551615" {
		t.Errorf("FromUint64(max) = %s", got)
	}
}

func TestSmallArithmeticMatchesInt64(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 20000; i++ {
		a := rng.Int63n(2_000_000_000_000) - 1_000_000_000_000
		b := rng.Int63n(2_000_000) - 1_000_000
		if i%7 == 0 {
			b = rng.Int63n(21) - 10
		}
		x, y := FromInt64(a), FromInt64(b)
		if got, want := x.Add(y).String(), FromInt64(a+b).String(); got != want {
			t.Fatalf("%d + %d = %s, want %s", a, b, got, want)
		}
		if got, want := x.Sub(y).String(), FromInt64(a-b).String(); got != want {
			t.Fatalf("%d - %d = %s, want %s", a, b, got, want)
		}
		if got, want := x.Mul(y).String(), FromInt64(a*b).String(); got != want {
			t.Fatalf("%d * %d = %s, want %s", a, b, got, want)
		}
		wantCmp := 0
		if a < b {
			wantCmp = -1
		} else if a > b {
			wantCmp = 1
		}
		if got := x.Cmp(y); got != wantCmp {
			t.Fatalf("Cmp(%d, %d) = %d", a, b, got)
		}
		if b != 0 {
			q, r, err := x.DivMod(y)
			if err != nil {
				t.Fatal(err)
			}
			if q.String() != FromInt64(a/b).String() || r.String() != FromInt64(a%b).String() {
				t.Fatalf("%d divmod %d = %s, %s; want %d, %d", a, b, q, r, a/b, a%b)
			}
		}
	}
}

func TestDivisionSigns(t *testing.T) {
	cases := []struct{ a, b, q, r string }{
		{"7", "2", "3", "1"}, {"-7", "2", "-3", "-1"},
		{"7", "-2", "-3", "1"}, {"-7", "-2", "3", "-1"},
		{"-1", "3", "0", "-1"}, {"-7", "7", "-1", "0"},
		{"0", "5", "0", "0"},
	}
	for _, c := range cases {
		q, r, err := MustParse(c.a).DivMod(MustParse(c.b))
		if err != nil || q.String() != c.q || r.String() != c.r {
			t.Errorf("%s divmod %s = %v, %v (%v); want %s, %s", c.a, c.b, q, r, err, c.q, c.r)
		}
	}
	if _, _, err := MustParse("5").DivMod(MustParse("-0")); err != ErrDivideByZero {
		t.Errorf("division by -0: err = %v", err)
	}
	if _, err := MustParse("0").Rem(&Int{}); err != ErrDivideByZero {
		t.Errorf("0 %% 0: err = %v", err)
	}
}

func TestNoNegativeZero(t *testing.T) {
	m5, z := MustParse("-5"), MustParse("-0")
	for name, got := range map[string]*Int{
		"mul":  m5.Mul(z),
		"add":  m5.Add(MustParse("5")),
		"sub":  m5.Sub(m5),
		"neg":  z.Neg(),
		"abs":  z.Abs(),
		"pow":  z.ExpUint64(3),
		"zero": z,
	} {
		if got.String() != "0" || got.Sign() != 0 {
			t.Errorf("%s: got %s sign %d", name, got, got.Sign())
		}
	}
	if r, _ := MustParse("-7").Rem(MustParse("7")); r.String() != "0" {
		t.Errorf("-7 %% 7 = %s", r)
	}
	if q, _ := MustParse("-1").Div(MustParse("2")); q.String() != "0" {
		t.Errorf("-1 / 2 = %s", q)
	}
}

func TestCarryAndBorrowChains(t *testing.T) {
	nines := MustParse(strings.Repeat("9", 100))
	one := FromInt64(1)
	sum := nines.Add(one)
	if want := "1" + strings.Repeat("0", 100); sum.String() != want {
		t.Errorf("carry chain: %s", sum)
	}
	if diff := sum.Sub(one); diff.Cmp(nines) != 0 {
		t.Errorf("borrow chain: %s", diff)
	}
	sq := nines.Mul(nines) // (10^100-1)^2 = 10^200 - 2·10^100 + 1
	want := strings.Repeat("9", 99) + "8" + strings.Repeat("0", 99) + "1"
	if sq.String() != want {
		t.Errorf("square of nines: %s", sq)
	}
}

func TestCmp(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"-0", "0", 0}, {"007", "7", 0}, {"-3", "-2", -1}, {"-2", "-3", 1},
		{"10", "9", 1}, {"-10", "9", -1}, {"1000000000", "999999999", 1},
		{"-1000000000", "-999999999", -1}, {"123456789123456789", "123456789123456790", -1},
	}
	for _, c := range cases {
		if got := MustParse(c.a).Cmp(MustParse(c.b)); got != c.want {
			t.Errorf("Cmp(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestExp(t *testing.T) {
	cases := []struct{ a, b, want string }{
		{"2", "10", "1024"}, {"0", "0", "1"}, {"0", "5", "0"}, {"5", "-0", "1"},
		{"-0", "-00", "1"}, {"-2", "3", "-8"}, {"-2", "2", "4"}, {"-1", "999", "-1"},
		{"7", "0", "1"}, {"-7", "1", "-7"}, {"10", "30", "1" + strings.Repeat("0", 30)},
		{"3", "0000040", "12157665459056928801"},
		{"-1", "99999999999999999999999999", "-1"}, {"1", "99999999999999999999999999", "1"},
		{"0", "99999999999999999999999999", "0"}, {"-1", "100000000000000000000000000", "1"},
	}
	for _, c := range cases {
		got, err := MustParse(c.a).Exp(MustParse(c.b))
		if err != nil || got.String() != c.want {
			t.Errorf("%s ^ %s = %v (%v), want %s", c.a, c.b, got, err, c.want)
		}
	}
	if _, err := MustParse("2").Exp(MustParse("-1")); err != ErrNegativeExponent {
		t.Errorf("2 ^ -1: err = %v", err)
	}
	if _, err := MustParse("2").Exp(MustParse("99999999999999999999999999")); err != ErrExponentTooLarge {
		t.Errorf("2 ^ huge: err = %v", err)
	}
}

func TestExpMatchesRepeatedMultiplication(t *testing.T) {
	for _, a := range []string{"2", "-3", "999999999", "1000000001", "123456789012345678901234567890"} {
		x := MustParse(a)
		acc := FromInt64(1)
		for e := uint64(0); e < 40; e++ {
			if got := x.ExpUint64(e); got.Cmp(acc) != 0 {
				t.Fatalf("%s^%d = %s, want %s", a, e, got, acc)
			}
			acc = acc.Mul(x)
		}
	}
}

func randomInt(rng *rand.Rand, maxLimbs int) *Int {
	n := 1 + rng.Intn(maxLimbs*baseDigits)
	var sb strings.Builder
	if rng.Intn(2) == 0 {
		sb.WriteByte('-')
	}
	for i := 0; i < n; i++ {
		switch rng.Intn(6) {
		case 0:
			sb.WriteByte('9') // provoke carries and qhat corrections
		case 1:
			sb.WriteByte('0')
		default:
			sb.WriteByte(byte('0' + rng.Intn(10)))
		}
	}
	return MustParse(sb.String())
}

func TestRandomIdentities(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 3000; i++ {
		a := randomInt(rng, 1+rng.Intn(30))
		b := randomInt(rng, 1+rng.Intn(15))
		if got := a.Add(b).Sub(b); got.Cmp(a) != 0 {
			t.Fatalf("(a+b)-b != a for a=%s b=%s", a, b)
		}
		if got := a.Sub(b).Add(b); got.Cmp(a) != 0 {
			t.Fatalf("(a-b)+b != a for a=%s b=%s", a, b)
		}
		if a.Mul(b).Cmp(b.Mul(a)) != 0 {
			t.Fatalf("a*b != b*a for a=%s b=%s", a, b)
		}
		if b.IsZero() {
			continue
		}
		q, r, err := a.DivMod(b)
		if err != nil {
			t.Fatal(err)
		}
		if back := q.Mul(b).Add(r); back.Cmp(a) != 0 {
			t.Fatalf("q*b+r != a for a=%s b=%s q=%s r=%s", a, b, q, r)
		}
		if r.Abs().Cmp(b.Abs()) >= 0 {
			t.Fatalf("|r| >= |b| for a=%s b=%s r=%s", a, b, r)
		}
		if !r.IsZero() && r.Sign() != a.Sign() {
			t.Fatalf("remainder sign for a=%s b=%s r=%s", a, b, r)
		}
		// Exact division round trip.
		if p, _ := a.Mul(b).Div(b); p.Cmp(a) != 0 {
			t.Fatalf("(a*b)/b != a for a=%s b=%s", a, b)
		}
	}
}

// Divisors built to trigger the rare "add back" step of Algorithm D.
func TestDivisionAddBack(t *testing.T) {
	b999 := "999999999"
	cases := [][2]string{
		{"1" + strings.Repeat("0", 27), b999 + b999 + b999},
		{strings.Repeat(b999, 6), strings.Repeat(b999, 3)},
		{strings.Repeat(b999, 6) + "000000000", "500000000" + "000000000" + "000000001"},
		{"499999999" + strings.Repeat("999999999", 5), "500000000" + "000000000" + "999999999"},
		{"800000000" + "000000000" + "000000000" + "000000003", "200000000" + "000000000" + "000000001"},
	}
	for _, c := range cases {
		a, b := MustParse(c[0]), MustParse(c[1])
		q, r, _ := a.DivMod(b)
		if q.Mul(b).Add(r).Cmp(a) != 0 || r.Cmp(b) >= 0 || r.Sign() < 0 {
			t.Errorf("bad division %s / %s: q=%s r=%s", a, b, q, r)
		}
	}
}

func TestLargeOperands(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	a := randomInt(rng, 2000).Abs()
	b := randomInt(rng, 900).Abs()
	p := a.Mul(b)
	if q, _ := p.Div(b); q.Cmp(a) != 0 {
		t.Error("large (a*b)/b != a")
	}
	if r, _ := p.Rem(b); !r.IsZero() {
		t.Error("large remainder of exact product is not zero")
	}
	if parsed := MustParse(p.String()); parsed.Cmp(p) != 0 {
		t.Error("large String/Parse round trip failed")
	}
	// (10^k)^2 string shape.
	k := MustParse("1" + strings.Repeat("0", 5000))
	if got := k.Mul(k).String(); got != "1"+strings.Repeat("0", 10000) {
		t.Error("10^5000 squared wrong")
	}
	if got := MustParse("10").ExpUint64(5000).String(); got != "1"+strings.Repeat("0", 5000) {
		t.Error("10^5000 wrong")
	}
}

func TestImmutability(t *testing.T) {
	a, b := MustParse("123456789012345678901234567890"), MustParse("-987654321987654321")
	as, bs := a.String(), b.String()
	a.Add(b)
	a.Sub(b)
	a.Mul(b)
	a.DivMod(b)
	b.Neg()
	b.Abs()
	a.ExpUint64(3)
	if a.String() != as || b.String() != bs {
		t.Error("operands were modified")
	}
}

func TestZeroValue(t *testing.T) {
	var z Int
	if z.String() != "0" || z.Sign() != 0 || !z.IsZero() {
		t.Error("zero value is not 0")
	}
	if got := z.Add(FromInt64(5)).String(); got != "5" {
		t.Errorf("0 + 5 = %s", got)
	}
}

func TestAppendTo(t *testing.T) {
	buf := []byte("x=")
	buf = MustParse("-1000000000000").AppendTo(buf)
	if string(buf) != "x=-1000000000000" {
		t.Errorf("AppendTo: %s", buf)
	}
}
