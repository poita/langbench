package vm

import (
	"math"
	"math/big"
	"testing"
)

func wantF(t *testing.T, got Value, want float64) {
	t.Helper()
	if got.P.Kind != KFloat {
		t.Fatalf("not a float")
	}
	g := got.F()
	if g != g && want != want {
		return
	}
	if fbits(g) != fbits(want) {
		t.Errorf("got %v (%#x), want %v (%#x)", g, fbits(g), want, fbits(want))
	}
}

func fl(x float64) Value { return Float(x) }

var negZero = math.Copysign(0, -1)

func TestShowFloat(t *testing.T) {
	p1, p2 := 0.1, 0.2
	nan := call("nanF").F()
	cases := []struct {
		x    float64
		d    int64
		want string
	}{
		{1.0, 6, "1.000000"}, {0.1, 6, "0.100000"}, {2.0 / 3.0, 6, "0.666667"},
		{negZero, 6, "-0.000000"}, {2.5, 0, "2"}, {3.5, 0, "4"}, {0.5, 0, "0"}, {1.5, 0, "2"},
		{1.0 / 3.0, 10, "0.3333333333"}, {p1 + p2, 17, "0.30000000000000004"},
		{1e21, 2, "1000000000000000000000.00"}, {nan, 3, "nan"},
		{math.Inf(1), 3, "inf"}, {math.Inf(-1), 3, "-inf"},
		{2.675, 2, "2.67"}, {-0.0000001, 2, "-0.00"}, {-1.5, 0, "-2"}, {-0.5, 0, "-0"},
		{math.Float64frombits(0xFFF8000000000001), 2, "nan"},
		{0.0, 0, "0"}, {0.0, 17, "0.00000000000000000"}, {123.456, 1, "123.5"},
		{5e-324, 17, "0.00000000000000000"},
	}
	for _, c := range cases {
		wantStr(t, call("showFloatAt", fl(c.x), Int(c.d)), c.want)
	}
	for _, x := range []float64{1e300, math.MaxFloat64, 123456789.123456789e10, 5e-324} {
		wantStr(t, call("showFloatAt", fl(x), Int(3)), new(big.Float).SetFloat64(x).Text('f', 3))
	}
	wantStr(t, call("showFloat", fl(1.5)), "1.500000")
	wantStr(t, call("showFloat", fl(negZero)), "-0.000000")
	wantStr(t, call("showFloat", call("sqrtF", fl(2))), "1.414214")
	wantStr(t, call("showFloat", call("piF")), "3.141593")
	wantStr(t, call("showFloat", call("toFloat", Int(9007199254740993))), "9007199254740992.000000")
	wantPanic(t, "digits out of range", "showFloatAt", fl(1), Int(-1))
	wantPanic(t, "digits out of range", "showFloatAt", fl(1), Int(18))
	wantPanic(t, "digits out of range", "showFloatAt", fl(nan), Int(18))
}

func TestFloatMath(t *testing.T) {
	wantF(t, call("sqrtF", fl(4)), 2)
	wantF(t, call("sqrtF", fl(negZero)), negZero)
	if !math.IsNaN(call("sqrtF", fl(-1)).F()) {
		t.Error("sqrt(-1)")
	}
	wantF(t, call("absF", fl(-3.5)), 3.5)
	wantF(t, call("absF", fl(negZero)), 0)
	wantF(t, call("floorF", fl(-2.5)), -3)
	wantF(t, call("floorF", fl(2.5)), 2)
	wantF(t, call("floorF", fl(negZero)), negZero)
	wantF(t, call("ceilF", fl(-0.5)), negZero)
	wantF(t, call("ceilF", fl(0.5)), 1)
	wantF(t, call("ceilF", fl(-2.5)), -2)
	wantF(t, call("truncF", fl(-0.9)), negZero)
	wantF(t, call("truncF", fl(-3.9)), -3)
	wantF(t, call("truncF", fl(3.9)), 3)
	wantF(t, call("roundF", fl(2.5)), 3)
	wantF(t, call("roundF", fl(-2.5)), -3)
	wantF(t, call("roundF", fl(-0.4)), negZero)
	wantF(t, call("roundF", fl(0.4)), 0)
	wantF(t, call("roundF", fl(0.5)), 1)
	wantF(t, call("roundF", fl(-0.5)), -1)
	wantF(t, call("roundF", fl(0.49999999999999994)), 0)
	wantF(t, call("roundF", fl(4503599627370497)), 4503599627370497)
	wantF(t, call("roundF", fl(math.Inf(-1))), math.Inf(-1))
	wantF(t, call("roundF", fl(negZero)), negZero)
	for _, fn := range []string{"floorF", "ceilF", "truncF", "roundF"} {
		if !math.IsNaN(call(fn, fl(math.NaN())).F()) {
			t.Error(fn, "nan")
		}
		wantF(t, call(fn, fl(math.Inf(1))), math.Inf(1))
	}
	wantF(t, call("toFloat", Int(9007199254740993)), 9007199254740992)
	wantF(t, call("toFloat", Int(9007199254740995)), 9007199254740996)
	wantF(t, call("toFloat", Int(math.MinInt64)), -9223372036854775808.0)
	wantF(t, call("infF"), math.Inf(1))
	if fbits(call("nanF").F()) != 0x7ff8000000000000 {
		t.Error("nanF bits")
	}
	wantF(t, call("piF"), math.Pi)
	wantInt(t, call("floatBits", fl(1.0)), 4607182418800017408)
	wantF(t, call("floatFromBits", Int(4607182418800017408)), 1.0)
	wantF(t, call("floatFromBits", Int(-1)), math.Float64frombits(math.MaxUint64))
	wantInt(t, call("floatBits", call("floatFromBits", Int(-1))), -1)
	wantInt(t, call("floatBits", fl(negZero)), math.MinInt64)
	wantBool(t, call("isNanF", fl(math.NaN())), true)
	wantBool(t, call("isNanF", fl(1)), false)
	wantBool(t, call("isInfF", fl(math.Inf(-1))), true)
	wantBool(t, call("isInfF", fl(1)), false)
	wantBool(t, call("isInfF", fl(math.NaN())), false)
}

func TestCmpMinMax(t *testing.T) {
	nan := math.NaN()
	wantInt(t, call("cmpF", fl(1), fl(2)), -1)
	wantInt(t, call("cmpF", fl(2), fl(1)), 1)
	wantInt(t, call("cmpF", fl(2), fl(2)), 0)
	wantInt(t, call("cmpF", fl(negZero), fl(0)), 0)
	wantInt(t, call("cmpF", fl(nan), fl(nan)), 0)
	wantInt(t, call("cmpF", fl(nan), fl(1)), 1)
	wantInt(t, call("cmpF", fl(1), fl(nan)), -1)
	wantInt(t, call("cmpF", fl(math.Inf(1)), fl(nan)), -1)
	wantF(t, call("minF", fl(nan), fl(1)), 1)
	if !math.IsNaN(call("maxF", fl(nan), fl(1)).F()) {
		t.Error("maxF(nan,1)")
	}
}

func TestMinMaxSpec(t *testing.T) {
	nan := math.NaN()
	// minF(a,b) = a when cmpF(a,b) <= 0 else b
	if !math.IsNaN(call("minF", fl(1), fl(nan)).F()) && call("minF", fl(1), fl(nan)).F() != 1 {
		t.Error("minF(1,nan)")
	}
	wantF(t, call("minF", fl(1), fl(nan)), 1)
	wantF(t, call("minF", fl(negZero), fl(0)), negZero)
	wantF(t, call("minF", fl(0), fl(negZero)), 0)
	wantF(t, call("maxF", fl(negZero), fl(0)), negZero)
	wantF(t, call("maxF", fl(3), fl(2)), 3)
	wantF(t, call("minF", fl(3), fl(2)), 2)
	wantF(t, call("maxF", fl(2), fl(3)), 3)
	if !math.IsNaN(call("maxF", fl(1), fl(nan)).F()) {
		// cmpF(1, nan) = -1, so maxF returns b = NaN
		t.Error("maxF(1,nan) should be NaN")
	}
}

func TestFmod(t *testing.T) {
	inf := math.Inf(1)
	wantF(t, call("fmodF", fl(5.5), fl(2)), 1.5)
	wantF(t, call("fmodF", fl(-5.5), fl(2)), -1.5)
	wantF(t, call("fmodF", fl(5.5), fl(-2)), 1.5)
	wantF(t, call("fmodF", fl(-4), fl(2)), negZero)
	wantF(t, call("fmodF", fl(4), fl(-2)), 0)
	wantF(t, call("fmodF", fl(negZero), fl(3)), negZero)
	wantF(t, call("fmodF", fl(3), fl(inf)), 3)
	wantF(t, call("fmodF", fl(-3), fl(math.Inf(-1))), -3)
	wantF(t, call("fmodF", fl(1), fl(0)), math.NaN())
	wantF(t, call("fmodF", fl(1), fl(negZero)), math.NaN())
	wantF(t, call("fmodF", fl(inf), fl(2)), math.NaN())
	wantF(t, call("fmodF", fl(math.NaN()), fl(2)), math.NaN())
	wantF(t, call("fmodF", fl(2), fl(math.NaN())), math.NaN())
	wantF(t, call("fmodF", fl(1e300), fl(3)), math.Mod(1e300, 3))
	wantF(t, call("fmodF", fl(0.3), fl(0.1)), 0.09999999999999998)
	wantF(t, call("fmodF", fl(1), fl(5e-324)), 0)
}

func TestPowF(t *testing.T) {
	wantF(t, call("powF", fl(2), Int(10)), 1024)
	wantF(t, call("powF", fl(2), Int(-2)), 0.25)
	wantF(t, call("powF", fl(2), Int(0)), 1)
	wantF(t, call("powF", fl(0), Int(0)), 1)
	wantF(t, call("powF", fl(math.NaN()), Int(0)), 1)
	wantF(t, call("powF", fl(0), Int(-1)), math.Inf(1))
	wantF(t, call("powF", fl(negZero), Int(-1)), math.Inf(-1))
	wantF(t, call("powF", fl(1.1), Int(7)), func() float64 {
		r, b := 1.0, 1.1
		k := 7
		for k > 0 {
			if k&1 == 1 {
				r = r * b
			}
			k >>= 1
			if k > 0 {
				b = b * b
			}
		}
		return r
	}())
	wantF(t, call("powF", fl(2), Int(2000)), math.Inf(1))
	wantF(t, call("powF", fl(2), Int(-2000)), 0)
	wantF(t, call("powF", fl(-2), Int(3)), -8)
	wantPanic(t, "negative exponent", "powF", fl(2), Int(math.MinInt64))
}

func TestTruncToInt(t *testing.T) {
	wantInt(t, call("truncToInt", fl(-3.9)), -3)
	wantInt(t, call("truncToInt", fl(3.9)), 3)
	wantInt(t, call("truncToInt", fl(negZero)), 0)
	wantInt(t, call("truncToInt", fl(-9223372036854775808.0)), math.MinInt64)
	wantInt(t, call("truncToInt", fl(9223372036854774784.0)), 9223372036854774784)
	wantInt(t, call("truncToInt", fl(-9223372036854775808.5)), math.MinInt64) // not representable: same double
	for _, x := range []float64{math.NaN(), math.Inf(1), math.Inf(-1), 9223372036854775808.0, -9223372036854777856.0, 1e300} {
		wantPanic(t, "float out of integer range", "truncToInt", fl(x))
	}
}

func TestParseFloat(t *testing.T) {
	ok := map[string]float64{
		"12": 12, "12.": 12, "12.5": 12.5, ".5": 0.5, "+.5": 0.5, "-.5": -0.5, "-0": negZero, "-0.0": negZero,
		"1e3": 1000, "1E3": 1000, "1e+3": 1000, "1e-3": 0.001, "1.5e2": 150, ".5e1": 5, "5.e1": 50,
		"0.1": 0.1, "007": 7, "1e400": math.Inf(1), "-1e400": math.Inf(-1), "1e-400": 0, "-1e-400": negZero,
		"4.9e-324": 5e-324, "1e99999999999999999999": math.Inf(1), "0e99999999999999999999": 0,
		"1.7976931348623157e308": math.MaxFloat64, "9007199254740993": 9007199254740992,
		"9007199254740993.0000000000000000000001": 9007199254740994,
		"0.30000000000000004":                     math.Float64frombits(0x3fd3333333333334),
	}
	for s, want := range ok {
		r := call("parseFloat", GoStr(s))
		if r.P.Var != VarSome {
			t.Errorf("parseFloat(%q) = None", s)
			continue
		}
		wantF(t, r.P.V[0], want)
	}
	bad := []string{"", "+", "-", ".", "+.", "e5", ".e5", "1e", "1e+", "1e-", "1 ", " 1", "1_0", "inf", "nan", "-inf",
		"Infinity", "0x1p3", "0x10", "1.2.3", "1e5.5", "--1", "1f", "1d", "١", "1,5", "\t1", "1e5 ", "1ee5", "++1", "+-1"}
	for _, s := range bad {
		if r := call("parseFloat", GoStr(s)); r.P.Var != VarNone {
			t.Errorf("parseFloat(%q) should be None", s)
		}
	}
	// long digit strings
	long := "0."
	for i := 0; i < 1000; i++ {
		long += "0"
	}
	long += "1e1000"
	r := call("parseFloat", GoStr(long))
	if r.P.Var != VarSome {
		t.Fatal("long")
	}
	wantF(t, r.P.V[0], 1e-1)
}
