package bigint

import (
	"errors"
	"math"
	"math/rand"
	"strings"
	"testing"
)

func mp(t testing.TB, s string) *Int {
	t.Helper()
	z, err := Parse(s)
	if err != nil {
		t.Fatalf("Parse(%q): %v", s, err)
	}
	return z
}

func randDigits(r *rand.Rand, n int) string {
	var sb strings.Builder
	sb.WriteByte(byte('1' + r.Intn(9)))
	for i := 1; i < n; i++ {
		// Bias toward 0s and 9s: these provoke carries, borrows and the
		// rare add-back step of Algorithm D.
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

func randInt(r *rand.Rand, maxDigits int) *Int {
	z := MustParse(randDigits(r, 1+r.Intn(maxDigits)))
	if r.Intn(2) == 0 {
		z = z.Neg()
	}
	return z
}

func TestParseString(t *testing.T) {
	tests := []struct{ in, want string }{
		{"0", "0"}, {"-0", "0"}, {"-000", "0"}, {"007", "7"}, {"-000123", "-123"},
		{"1000000000", "1000000000"}, {"999999999", "999999999"},
		{"1000000000000000000", "1000000000000000000"},
		{"-1000000001", "-1000000001"},
		{"123456789012345678901234567890", "123456789012345678901234567890"},
	}
	for _, tc := range tests {
		if got := mp(t, tc.in).String(); got != tc.want {
			t.Errorf("Parse(%q).String() = %q, want %q", tc.in, got, tc.want)
		}
	}
	for _, bad := range []string{"", "-", "+1", "1 2", "1e5", "--1", "a", "1_0"} {
		if _, err := Parse(bad); !errors.Is(err, ErrSyntax) {
			t.Errorf("Parse(%q) error = %v, want ErrSyntax", bad, err)
		}
	}
}

func TestZeroValue(t *testing.T) {
	var z Int
	if z.String() != "0" || z.Sign() != 0 {
		t.Errorf("zero value = %q sign %d", z.String(), z.Sign())
	}
	if got := z.Add(FromInt64(5)).String(); got != "5" {
		t.Errorf("0+5 = %s", got)
	}
}

func TestFromInt64(t *testing.T) {
	for _, v := range []int64{0, 1, -1, 999999999, 1000000000, math.MaxInt64, math.MinInt64} {
		want := MustParse(strings.TrimSpace(itoa(v)))
		if got := FromInt64(v); got.Cmp(want) != 0 || got.String() != itoa(v) {
			t.Errorf("FromInt64(%d) = %s", v, got)
		}
	}
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	u := uint64(v)
	if neg {
		u = -u
	}
	var b []byte
	for ; u > 0; u /= 10 {
		b = append([]byte{byte('0' + u%10)}, b...)
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

type binop struct {
	a, op, b, want string
}

func TestSpecExamples(t *testing.T) {
	tests := []binop{
		{"12", "+", "30", "42"},
		{"5", "-", "7", "-2"},
		{"-7", "/", "2", "-3"},
		{"-7", "%", "2", "-1"},
		{"-0", "+", "0", "0"},
		{"-5", "*", "0", "0"},
		{"99999999999999999999", "+", "1", "100000000000000000000"},
		{"2", "^", "10", "1024"},
		{"0", "^", "0", "1"},
		{"-123456789012345678901234567890", "*", "987654321098765432109876543210",
			"-121932631137021795226185032733622923332237463801111263526900"},
		{"1000000000000000000000000000000", "-", "1", "999999999999999999999999999999"},
		{"7", "/", "2", "3"}, {"7", "/", "-2", "-3"}, {"-7", "/", "-2", "3"},
		{"7", "%", "2", "1"}, {"7", "%", "-2", "1"}, {"-7", "%", "-2", "-1"},
		{"-1", "/", "2", "0"}, {"-1", "/", "3", "0"}, {"-1", "%", "3", "-1"},
		{"-7", "%", "7", "0"},
		{"5", "^", "-0", "1"}, {"-0", "^", "-00", "1"}, {"0", "^", "5", "0"},
		{"-2", "^", "3", "-8"}, {"-2", "^", "2", "4"}, {"-1", "^", "999", "-1"},
		{"007", "^", "2", "49"},
	}
	for _, tc := range tests {
		got, err := apply(mp(t, tc.a), tc.op, mp(t, tc.b))
		if err != nil || got.String() != tc.want {
			t.Errorf("%s %s %s = %v, %v; want %s", tc.a, tc.op, tc.b, got, err, tc.want)
		}
	}
}

func apply(a *Int, op string, b *Int) (*Int, error) {
	switch op {
	case "+":
		return a.Add(b), nil
	case "-":
		return a.Sub(b), nil
	case "*":
		return a.Mul(b), nil
	case "/":
		return a.Quo(b)
	case "%":
		return a.Rem(b)
	case "^":
		return a.Exp(b)
	}
	panic("bad op")
}

func TestErrors(t *testing.T) {
	if _, err := mp(t, "1").Quo(mp(t, "-0")); !errors.Is(err, ErrDivByZero) {
		t.Errorf("1 / -0: err = %v", err)
	}
	if _, err := mp(t, "0").Rem(mp(t, "0")); !errors.Is(err, ErrDivByZero) {
		t.Errorf("0 %% 0: err = %v", err)
	}
	if _, _, err := mp(t, "0").QuoRem(mp(t, "0")); !errors.Is(err, ErrDivByZero) {
		t.Errorf("QuoRem 0/0: err = %v", err)
	}
	if _, err := mp(t, "2").Exp(mp(t, "-1")); !errors.Is(err, ErrNegativeExponent) {
		t.Errorf("2 ^ -1: err = %v", err)
	}
	if _, err := mp(t, "2").Exp(mp(t, "100000000000000000000")); !errors.Is(err, ErrExponentTooLarge) {
		t.Errorf("2 ^ 1e20: err = %v", err)
	}
	huge := mp(t, "100000000000000000001") // odd, > MaxUint64
	for base, want := range map[string]string{"0": "0", "1": "1", "-1": "-1"} {
		got, err := mp(t, base).Exp(huge)
		if err != nil || got.String() != want {
			t.Errorf("%s ^ huge = %v, %v; want %s", base, got, err, want)
		}
	}
}

func TestCmp(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"-0", "0", 0}, {"007", "7", 0}, {"-3", "-2", -1}, {"-2", "-3", 1},
		{"-1", "1", -1}, {"1", "-1", 1}, {"10", "9", 1}, {"0", "-1", 1},
		{"1000000000", "999999999", 1},
	}
	for _, tc := range tests {
		if got := mp(t, tc.a).Cmp(mp(t, tc.b)); got != tc.want {
			t.Errorf("cmp(%s, %s) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestSignHelpers(t *testing.T) {
	if mp(t, "-5").Abs().String() != "5" || mp(t, "5").Neg().String() != "-5" || mp(t, "0").Neg().String() != "0" {
		t.Error("Abs/Neg wrong")
	}
	if mp(t, "-5").Sign() != -1 || mp(t, "5").Sign() != 1 {
		t.Error("Sign wrong")
	}
}

// Small values must agree with machine arithmetic.
func TestAgainstInt64(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for i := 0; i < 20000; i++ {
		x := r.Int63n(2_000_000_000_000) - 1_000_000_000_000
		y := r.Int63n(2_000_000) - 1_000_000
		if i%3 == 0 {
			y = r.Int63n(2_000_000_000_000) - 1_000_000_000_000
		}
		a, b := FromInt64(x), FromInt64(y)
		check := func(op string, got *Int, want int64) {
			if got.String() != itoa(want) {
				t.Fatalf("%d %s %d = %s, want %d", x, op, y, got, want)
			}
		}
		check("+", a.Add(b), x+y)
		check("-", a.Sub(b), x-y)
		if y > -3_000_000 && y < 3_000_000 { // product fits in int64
			check("*", a.Mul(b), x*y)
		}
		if y != 0 {
			q, _ := a.Quo(b)
			rm, _ := a.Rem(b)
			check("/", q, x/y)
			check("%", rm, x%y)
		}
		want := 0
		if x < y {
			want = -1
		} else if x > y {
			want = 1
		}
		if a.Cmp(b) != want {
			t.Fatalf("cmp(%d,%d)", x, y)
		}
	}
}

// refMul is an independent digit-by-digit decimal schoolbook multiplication
// used to cross-check the base-10^9 implementation.
func refMul(a, b string) string {
	res := make([]int, len(a)+len(b))
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			res[i+j+1] += int(a[i]-'0') * int(b[j]-'0')
		}
	}
	for k := len(res) - 1; k > 0; k-- {
		res[k-1] += res[k] / 10
		res[k] %= 10
	}
	var sb strings.Builder
	for _, d := range res {
		sb.WriteByte(byte('0' + d))
	}
	return strings.TrimLeft(sb.String(), "0")
}

func TestMulAgainstReference(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 300; i++ {
		a, b := randDigits(r, 1+r.Intn(200)), randDigits(r, 1+r.Intn(200))
		want := refMul(a, b)
		if got := mp(t, a).Mul(mp(t, b)).String(); got != want {
			t.Fatalf("%s * %s = %s, want %s", a, b, got, want)
		}
	}
}

func TestAddSubIdentities(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 2000; i++ {
		a, b := randInt(r, 120), randInt(r, 120)
		if s := a.Add(b); s.Sub(b).Cmp(a) != 0 || s.Sub(a).Cmp(b) != 0 {
			t.Fatalf("add/sub mismatch %s %s", a, b)
		}
		if a.Sub(a).Sign() != 0 || a.Add(a.Neg()).String() != "0" {
			t.Fatalf("a-a != 0 for %s", a)
		}
		if a.Add(b).Cmp(b.Add(a)) != 0 || a.Mul(b).Cmp(b.Mul(a)) != 0 {
			t.Fatalf("commutativity %s %s", a, b)
		}
	}
}

func checkDiv(t *testing.T, a, b *Int) {
	t.Helper()
	q, r, err := a.QuoRem(b)
	if err != nil {
		t.Fatal(err)
	}
	if back := q.Mul(b).Add(r); back.Cmp(a) != 0 {
		t.Fatalf("%s / %s: q=%s r=%s does not reconstruct (got %s)", a, b, q, r, back)
	}
	if r.Abs().Cmp(b.Abs()) >= 0 {
		t.Fatalf("%s / %s: |r|=%s >= |b|", a, b, r.Abs())
	}
	if r.Sign() != 0 && r.Sign() != a.Sign() {
		t.Fatalf("%s %% %s = %s has wrong sign", a, b, r)
	}
}

func TestDivisionRandom(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for i := 0; i < 5000; i++ {
		checkDiv(t, randInt(r, 150), randInt(r, 1+r.Intn(100)))
	}
}

// Structured operands stress the quotient estimate and the add-back step.
func TestDivisionEdgeCases(t *testing.T) {
	pow := func(k int) string { return "1" + strings.Repeat("0", k) }
	nines := func(k int) string { return strings.Repeat("9", k) }
	var ops []string
	for _, k := range []int{1, 8, 9, 10, 17, 18, 19, 27, 36, 45} {
		ops = append(ops, pow(k), nines(k), "5"+pow(k-1), "4"+nines(k-1))
	}
	ops = append(ops, "999999999"+"000000000"+"000000001", "500000000"+"000000000"+"000000001")
	for _, as := range ops {
		for _, bs := range ops {
			for _, adj := range []int64{-1, 0, 1} {
				a := mp(t, as).Mul(mp(t, bs)).Add(FromInt64(adj))
				checkDiv(t, a, mp(t, bs))
				checkDiv(t, mp(t, as), mp(t, bs).Add(FromInt64(adj)).Add(FromInt64(1)))
				checkDiv(t, a.Neg(), mp(t, bs))
			}
		}
	}
	// Classic add-back trigger in base 10^9 analogue of Hacker's Delight cases.
	checkDiv(t, mp(t, "999999999999999999999999999999999999"), mp(t, "999999999000000000000000001"))
}

func TestDivisionLarge(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	a, b := mp(t, randDigits(r, 5000)), mp(t, randDigits(r, 2500))
	checkDiv(t, a, b)
	checkDiv(t, a.Neg(), b)
	checkDiv(t, a, b.Neg())
}

func TestExp(t *testing.T) {
	r := rand.New(rand.NewSource(6))
	for i := 0; i < 200; i++ {
		a := randInt(r, 30)
		e := r.Intn(40)
		want := FromInt64(1)
		for k := 0; k < e; k++ {
			want = want.Mul(a)
		}
		got, err := a.Exp(FromInt64(int64(e)))
		if err != nil || got.Cmp(want) != 0 {
			t.Fatalf("%s ^ %d = %v (%v), want %s", a, e, got, err, want)
		}
	}
	got, _ := mp(t, "2").Exp(mp(t, "5000"))
	if len(got.String()) != 1506 || !strings.HasPrefix(got.String(), "1412") {
		t.Errorf("2^5000 has %d digits, prefix %s", len(got.String()), got.String()[:6])
	}
}

func TestImmutability(t *testing.T) {
	a, b := mp(t, "123456789123456789123456789"), mp(t, "987654321987654321")
	as, bs := a.String(), b.String()
	a.Add(b)
	a.Sub(b)
	a.Mul(b)
	a.QuoRem(b)
	a.Exp(FromInt64(3))
	if a.String() != as || b.String() != bs {
		t.Error("operands were modified")
	}
}

func BenchmarkMul50000(b *testing.B) {
	r := rand.New(rand.NewSource(7))
	x, y := MustParse(randDigits(r, 50000)), MustParse(randDigits(r, 50000))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		x.Mul(y)
	}
}

func BenchmarkDiv50000by25000(b *testing.B) {
	r := rand.New(rand.NewSource(8))
	x, y := MustParse(randDigits(r, 50000)), MustParse(randDigits(r, 25000))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		x.QuoRem(y)
	}
}
