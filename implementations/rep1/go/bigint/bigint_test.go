package bigint

import (
	"errors"
	"math/rand"
	"strings"
	"testing"
)

func TestParseString(t *testing.T) {
	tests := []struct{ in, want string }{
		{"0", "0"},
		{"-0", "0"},
		{"-000", "0"},
		{"007", "7"},
		{"-000123", "-123"},
		{"999999999", "999999999"},
		{"1000000000", "1000000000"},
		{"1000000001", "1000000001"},
		{"-123456789012345678901234567890", "-123456789012345678901234567890"},
		{"000000000000000000000000000001", "1"},
	}
	for _, tc := range tests {
		x, err := Parse(tc.in)
		if err != nil {
			t.Errorf("Parse(%q): %v", tc.in, err)
			continue
		}
		if got := x.String(); got != tc.want {
			t.Errorf("Parse(%q).String() = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"", "-", "+1", "1 2", "1e5", "--1", "0x10", "١٢"} {
		if _, err := Parse(s); !errors.Is(err, ErrSyntax) {
			t.Errorf("Parse(%q) error = %v, want ErrSyntax", s, err)
		}
	}
}

func TestNew(t *testing.T) {
	tests := []struct {
		in   int64
		want string
	}{
		{0, "0"}, {1, "1"}, {-1, "-1"}, {1_000_000_000, "1000000000"},
		{9223372036854775807, "9223372036854775807"},
		{-9223372036854775808, "-9223372036854775808"},
	}
	for _, tc := range tests {
		if got := New(tc.in).String(); got != tc.want {
			t.Errorf("New(%d) = %s, want %s", tc.in, got, tc.want)
		}
	}
}

func TestZeroValue(t *testing.T) {
	var z Int
	if z.String() != "0" || z.Sign() != 0 {
		t.Errorf("zero value = %s (sign %d)", z.String(), z.Sign())
	}
	if got := z.Add(New(5)).String(); got != "5" {
		t.Errorf("0+5 = %s", got)
	}
}

func TestArithmeticTable(t *testing.T) {
	tests := []struct{ a, op, b, want string }{
		{"12", "+", "30", "42"},
		{"5", "-", "7", "-2"},
		{"-0", "+", "0", "0"},
		{"-5", "*", "0", "0"},
		{"99999999999999999999", "+", "1", "100000000000000000000"},
		{"1000000000000000000000000000000", "-", "1", "999999999999999999999999999999"},
		{"-123456789012345678901234567890", "*", "987654321098765432109876543210",
			"-121932631137021795226185032733622923332237463801111263526900"},
		{"7", "/", "2", "3"}, {"-7", "/", "2", "-3"}, {"7", "/", "-2", "-3"}, {"-7", "/", "-2", "3"},
		{"7", "%", "2", "1"}, {"-7", "%", "2", "-1"}, {"7", "%", "-2", "1"}, {"-7", "%", "-2", "-1"},
		{"-1", "/", "2", "0"}, {"-1", "/", "3", "0"}, {"-1", "%", "3", "-1"}, {"-7", "%", "7", "0"},
		{"2", "^", "10", "1024"}, {"0", "^", "0", "1"}, {"0", "^", "5", "0"},
		{"-2", "^", "3", "-8"}, {"-2", "^", "2", "4"}, {"-1", "^", "999", "-1"},
		{"5", "^", "-0", "1"}, {"-0", "^", "-00", "1"},
		{"1", "^", "99999999999999999999999", "1"},
		{"-1", "^", "99999999999999999999999", "-1"},
		{"0", "^", "99999999999999999999999", "0"},
		{"10", "^", "30", "1000000000000000000000000000000"},
		{"1000000000000000000", "/", "1000000000", "1000000000"},
		{"1000000000000000000", "%", "999999999", "1"},
	}
	for _, tc := range tests {
		a, b := MustParse(tc.a), MustParse(tc.b)
		var got *Int
		var err error
		switch tc.op {
		case "+":
			got = a.Add(b)
		case "-":
			got = a.Sub(b)
		case "*":
			got = a.Mul(b)
		case "/":
			got, err = a.Quo(b)
		case "%":
			got, err = a.Rem(b)
		case "^":
			got, err = a.Exp(b)
		}
		if err != nil {
			t.Errorf("%s %s %s: unexpected error %v", tc.a, tc.op, tc.b, err)
		} else if got.String() != tc.want {
			t.Errorf("%s %s %s = %s, want %s", tc.a, tc.op, tc.b, got, tc.want)
		}
	}
}

func TestErrors(t *testing.T) {
	if _, _, err := New(1).QuoRem(New(0)); !errors.Is(err, ErrDivisionByZero) {
		t.Errorf("1/0: %v", err)
	}
	if _, err := New(0).Rem(MustParse("-000")); !errors.Is(err, ErrDivisionByZero) {
		t.Errorf("0%%-0: %v", err)
	}
	if _, err := New(2).Exp(New(-1)); !errors.Is(err, ErrNegativeExponent) {
		t.Errorf("2^-1: %v", err)
	}
	if _, err := New(2).Exp(MustParse("100000000000000000000")); !errors.Is(err, ErrExponentTooLarge) {
		t.Errorf("2^1e20: %v", err)
	}
}

func TestCmp(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"-0", "0", 0}, {"007", "7", 0}, {"-3", "-2", -1}, {"-2", "-3", 1},
		{"1", "-1", 1}, {"-1", "1", -1}, {"10", "9", 1},
		{"1000000000", "999999999", 1}, {"-1000000000", "-999999999", -1},
	}
	for _, tc := range tests {
		if got := MustParse(tc.a).Cmp(MustParse(tc.b)); got != tc.want {
			t.Errorf("cmp(%s, %s) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestSignHelpers(t *testing.T) {
	if New(0).Neg().String() != "0" || New(0).Neg().Sign() != 0 {
		t.Error("-0 must be 0")
	}
	if got := New(-5).Abs().String(); got != "5" {
		t.Errorf("Abs(-5) = %s", got)
	}
	if got := New(5).Neg().String(); got != "-5" {
		t.Errorf("Neg(5) = %s", got)
	}
}

func TestImmutability(t *testing.T) {
	a, b := MustParse("123456789012345678901234567890"), MustParse("-987654321098765432109")
	as, bs := a.String(), b.String()
	a.Add(b)
	a.Sub(b)
	a.Mul(b)
	a.QuoRem(b)
	a.Exp(New(7))
	if a.String() != as || b.String() != bs {
		t.Error("operands were modified")
	}
}

// (10^k - 1)^2 has the decimal digit pattern 99..9800..01.
func TestMulNines(t *testing.T) {
	for _, k := range []int{1, 8, 9, 10, 17, 18, 19, 100, 1000} {
		a := MustParse(strings.Repeat("9", k))
		want := strings.Repeat("9", k-1) + "8" + strings.Repeat("0", k-1) + "1"
		if got := a.Mul(a).String(); got != want {
			t.Errorf("k=%d: got %s, want %s", k, got, want)
		}
	}
}

func TestPowerOfTen(t *testing.T) {
	p, _ := New(10).Exp(New(5000))
	if want := "1" + strings.Repeat("0", 5000); p.String() != want {
		t.Error("10^5000 mismatch")
	}
	// 2^64
	p, _ = New(2).Exp(New(64))
	if p.String() != "18446744073709551616" {
		t.Errorf("2^64 = %s", p)
	}
}

// randDigits returns a random decimal string, biased toward limb patterns that
// stress carries and the quotient-digit estimate (all 9s, all 0s).
func randDigits(r *rand.Rand, maxLen int) string {
	n := 1 + r.Intn(maxLen)
	var sb strings.Builder
	for sb.Len() < n {
		switch r.Intn(6) {
		case 0:
			sb.WriteString("999999999")
		case 1:
			sb.WriteString("000000000")
		case 2:
			sb.WriteString("500000000")
		case 3:
			sb.WriteString("000000001")
		default:
			for i := 0; i < 9; i++ {
				sb.WriteByte(byte('0' + r.Intn(10)))
			}
		}
	}
	s := strings.TrimLeft(sb.String()[:n], "0")
	if s == "" {
		s = "0"
	}
	if r.Intn(2) == 0 && s != "0" {
		s = "-" + s
	}
	return s
}

func TestRandomProperties(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for iter := 0; iter < 3000; iter++ {
		a := MustParse(randDigits(r, 120))
		b := MustParse(randDigits(r, 120))
		c := MustParse(randDigits(r, 60))

		// (a+b)-b == a, a-b == -(b-a), a+b == b+a
		if a.Add(b).Sub(b).Cmp(a) != 0 {
			t.Fatalf("(a+b)-b != a for a=%s b=%s", a, b)
		}
		if a.Sub(b).Cmp(b.Sub(a).Neg()) != 0 {
			t.Fatalf("a-b != -(b-a) for a=%s b=%s", a, b)
		}
		// commutativity and distributivity of multiplication
		if a.Mul(b).Cmp(b.Mul(a)) != 0 {
			t.Fatalf("a*b != b*a for a=%s b=%s", a, b)
		}
		if a.Mul(b.Add(c)).Cmp(a.Mul(b).Add(a.Mul(c))) != 0 {
			t.Fatalf("distributivity failed for %s %s %s", a, b, c)
		}
		// division identity
		if b.Sign() != 0 {
			q, rem, err := a.QuoRem(b)
			if err != nil {
				t.Fatal(err)
			}
			if q.Mul(b).Add(rem).Cmp(a) != 0 {
				t.Fatalf("a != q*b+r for a=%s b=%s q=%s r=%s", a, b, q, rem)
			}
			if rem.Abs().Cmp(b.Abs()) >= 0 {
				t.Fatalf("|r| >= |b| for a=%s b=%s r=%s", a, b, rem)
			}
			if rem.Sign() != 0 && rem.Sign() != a.Sign() {
				t.Fatalf("remainder sign wrong: a=%s b=%s r=%s", a, b, rem)
			}
		}
		// round trip through text
		if MustParse(a.String()).Cmp(a) != 0 {
			t.Fatalf("round trip failed for %s", a)
		}
	}
}

// TestDivisionExact builds a = q*b + r from known q, b, r and checks that
// division recovers q and r exactly, exercising Algorithm D's correction steps.
func TestDivisionExact(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for iter := 0; iter < 3000; iter++ {
		b := MustParse(strings.TrimPrefix(randDigits(r, 90), "-"))
		if b.Sign() == 0 {
			continue
		}
		q := MustParse(strings.TrimPrefix(randDigits(r, 90), "-"))
		rem := MustParse(strings.TrimPrefix(randDigits(r, 90), "-")).Add(New(0))
		_, rem, _ = rem.QuoRem(b) // ensure 0 <= rem < b
		a := q.Mul(b).Add(rem)
		gq, gr, err := a.QuoRem(b)
		if err != nil || gq.Cmp(q) != 0 || gr.Cmp(rem) != 0 {
			t.Fatalf("a=%s b=%s: got q=%s r=%s, want q=%s r=%s", a, b, gq, gr, q, rem)
		}
	}
}

func TestExpMatchesRepeatedMul(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for iter := 0; iter < 200; iter++ {
		a := MustParse(randDigits(r, 40))
		e := r.Intn(40)
		want := New(1)
		for i := 0; i < e; i++ {
			want = want.Mul(a)
		}
		got, err := a.Exp(New(int64(e)))
		if err != nil || got.Cmp(want) != 0 {
			t.Fatalf("%s^%d mismatch", a, e)
		}
	}
}

// TestSmallAgainstMachineInts checks every operation against int64 arithmetic
// on small operands.
func TestSmallAgainstMachineInts(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for iter := 0; iter < 20000; iter++ {
		x := r.Int63n(2_000_000_001) - 1_000_000_000
		y := r.Int63n(2_000_001) - 1_000_000
		a, b := New(x), New(y)
		check := func(name string, got *Int, want int64) {
			if got.String() != New(want).String() {
				t.Fatalf("%d %s %d = %s, want %d", x, name, y, got, want)
			}
		}
		check("+", a.Add(b), x+y)
		check("-", a.Sub(b), x-y)
		check("*", a.Mul(b), x*y)
		if y != 0 {
			q, rem, _ := a.QuoRem(b)
			check("/", q, x/y)
			check("%", rem, x%y)
		}
		cmp := 0
		if x < y {
			cmp = -1
		} else if x > y {
			cmp = 1
		}
		if a.Cmp(b) != cmp {
			t.Fatalf("cmp(%d,%d)", x, y)
		}
	}
}

func FuzzQuoRem(f *testing.F) {
	f.Add("123456789012345678901234567890", "987654321")
	f.Add("-1000000000000000000", "999999999")
	f.Fuzz(func(t *testing.T, as, bs string) {
		a, err1 := Parse(as)
		b, err2 := Parse(bs)
		if err1 != nil || err2 != nil || b.Sign() == 0 {
			return
		}
		q, r, _ := a.QuoRem(b)
		if q.Mul(b).Add(r).Cmp(a) != 0 || r.Abs().Cmp(b.Abs()) >= 0 {
			t.Fatalf("division identity violated for %s / %s", as, bs)
		}
	})
}

func BenchmarkMul50k(b *testing.B) {
	x := MustParse(strings.Repeat("123456789", 5555))
	for i := 0; i < b.N; i++ {
		x.Mul(x)
	}
}

func BenchmarkDiv50kBy25k(b *testing.B) {
	x := MustParse(strings.Repeat("987654321", 5555))
	y := MustParse(strings.Repeat("123456789", 2777))
	for i := 0; i < b.N; i++ {
		x.QuoRem(y)
	}
}
