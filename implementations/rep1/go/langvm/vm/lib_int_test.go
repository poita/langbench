package vm

import (
	"math"
	"testing"
)

func TestIntBasics(t *testing.T) {
	wantInt(t, call("intMin"), math.MinInt64)
	wantInt(t, call("intMax"), math.MaxInt64)
	wantInt(t, call("absI", Int(-5)), 5)
	wantInt(t, call("absI", Int(math.MinInt64)), math.MinInt64)
	wantInt(t, call("minI", Int(3), Int(-4)), -4)
	wantInt(t, call("maxI", Int(3), Int(-4)), 3)
	wantInt(t, call("signI", Int(-9)), -1)
	wantInt(t, call("signI", Int(0)), 0)
	wantInt(t, call("signI", Int(9)), 1)
	wantInt(t, call("cmpI", Int(1), Int(2)), -1)
	wantInt(t, call("cmpI", Int(2), Int(2)), 0)
	wantInt(t, call("cmpI", Int(3), Int(2)), 1)
}

func TestDivModFloor(t *testing.T) {
	cases := []struct{ a, b, q, r int64 }{
		{-7, 2, -4, 1}, {7, -2, -4, -1}, {7, 2, 3, 1}, {-7, -2, 3, -1},
		{6, 3, 2, 0}, {-6, 3, -2, 0}, {0, 5, 0, 0}, {5, 1, 5, 0}, {-5, -1, 5, 0},
		{math.MinInt64, -1, math.MinInt64, 0},
		{math.MinInt64, 2, math.MinInt64 / 2, 0},
		{math.MaxInt64, -1, -math.MaxInt64, 0},
	}
	for _, c := range cases {
		wantInt(t, call("divFloor", Int(c.a), Int(c.b)), c.q)
		wantInt(t, call("modFloor", Int(c.a), Int(c.b)), c.r)
	}
	wantPanic(t, "divide by zero", "divFloor", Int(1), Int(0))
	wantPanic(t, "modulo by zero", "modFloor", Int(1), Int(0))
}

func TestPowGcdBits(t *testing.T) {
	wantInt(t, call("powI", Int(3), Int(20)), 3486784401)
	wantInt(t, call("powI", Int(5), Int(0)), 1)
	wantInt(t, call("powI", Int(0), Int(0)), 1)
	wantInt(t, call("powI", Int(-2), Int(3)), -8)
	wantInt(t, call("powI", Int(2), Int(63)), math.MinInt64)
	wantInt(t, call("powI", Int(2), Int(64)), 0)
	wantInt(t, call("powI", Int(3), Int(100)), int64(func() uint64 {
		r := uint64(1)
		for i := 0; i < 100; i++ {
			r *= 3
		}
		return r
	}()))
	wantPanic(t, "negative exponent", "powI", Int(2), Int(-1))

	wantInt(t, call("gcdI", Int(-84), Int(36)), 12)
	wantInt(t, call("gcdI", Int(0), Int(0)), 0)
	wantInt(t, call("gcdI", Int(0), Int(-7)), 7)
	wantInt(t, call("gcdI", Int(math.MinInt64), Int(0)), math.MinInt64)
	wantInt(t, call("gcdI", Int(math.MinInt64), Int(6)), 2)
	wantInt(t, call("gcdI", Int(math.MinInt64), Int(math.MinInt64)), math.MinInt64)

	wantInt(t, call("popCount", Int(255)), 8)
	wantInt(t, call("popCount", Int(-1)), 64)
	wantInt(t, call("clz", Int(1)), 63)
	wantInt(t, call("clz", Int(0)), 64)
	wantInt(t, call("clz", Int(-1)), 0)
	wantInt(t, call("ctz", Int(8)), 3)
	wantInt(t, call("ctz", Int(0)), 64)
}

func TestShowInt(t *testing.T) {
	wantStr(t, call("showInt", Int(0)), "0")
	wantStr(t, call("showInt", Int(-42)), "-42")
	wantStr(t, call("showInt", Int(math.MinInt64)), "-9223372036854775808")
	wantStr(t, call("showInt", Int(math.MaxInt64)), "9223372036854775807")
	wantStr(t, call("showIntRadix", Int(255), Int(16)), "ff")
	wantStr(t, call("showIntRadix", Int(-255), Int(2)), "-11111111")
	wantStr(t, call("showIntRadix", Int(0), Int(7)), "0")
	wantStr(t, call("showIntRadix", Int(35), Int(36)), "z")
	wantStr(t, call("showIntRadix", Int(math.MinInt64), Int(2)), "-1"+"000000000000000000000000000000000000000000000000000000000000000")
	wantStr(t, call("showIntRadix", Int(math.MinInt64), Int(16)), "-8000000000000000")
	wantPanic(t, "radix out of range", "showIntRadix", Int(1), Int(1))
	wantPanic(t, "radix out of range", "showIntRadix", Int(1), Int(37))
	wantPanic(t, "radix out of range", "showIntRadix", Int(1), Int(-3))
}

func wantOptInt(t *testing.T, got Value, want int64, some bool) {
	t.Helper()
	if !some {
		if got.P.Var != VarNone {
			t.Errorf("want None, got Some(%d)", got.P.V[0].N)
		}
		return
	}
	if got.P.Var != VarSome || got.P.V[0].N != want {
		t.Errorf("want Some(%d), got %+v", want, got.P)
	}
}

func TestParseInt(t *testing.T) {
	ok := map[string]int64{
		"0": 0, "-0": 0, "+0": 0, "42": 42, "+42": 42, "-42": -42, "-0042": -42, "007": 7,
		"9223372036854775807": math.MaxInt64, "-9223372036854775808": math.MinInt64,
		"+9223372036854775807":          math.MaxInt64,
		"00000000000000000000000000009": 9,
	}
	for s, v := range ok {
		wantOptInt(t, call("parseInt", GoStr(s)), v, true)
	}
	bad := []string{"", "+", "-", "x", " 1", "1 ", "1_0", "0x10", "--1", "+-1", "1.0", "1e3", "٣",
		"9223372036854775808", "-9223372036854775809", "99999999999999999999999", "18446744073709551616",
		"1a", "a1", "\n1"}
	for _, s := range bad {
		wantOptInt(t, call("parseInt", GoStr(s)), 0, false)
	}
	wantOptInt(t, call("parseIntRadix", GoStr("ff"), Int(16)), 255, true)
	wantOptInt(t, call("parseIntRadix", GoStr("FF"), Int(16)), 255, true)
	wantOptInt(t, call("parseIntRadix", GoStr("-Zz"), Int(36)), -(35*36 + 35), true)
	wantOptInt(t, call("parseIntRadix", GoStr("102"), Int(2)), 0, false)
	wantOptInt(t, call("parseIntRadix", GoStr("g"), Int(16)), 0, false)
	wantOptInt(t, call("parseIntRadix", GoStr("101"), Int(2)), 5, true)
	wantOptInt(t, call("parseIntRadix", GoStr("-8000000000000000"), Int(16)), math.MinInt64, true)
	wantOptInt(t, call("parseIntRadix", GoStr("8000000000000000"), Int(16)), 0, false)
	wantOptInt(t, call("parseIntRadix", GoStr("7fffffffffffffff"), Int(16)), math.MaxInt64, true)
	wantOptInt(t, call("parseIntRadix", GoStr("0x1"), Int(16)), 0, false)
	wantOptInt(t, call("parseIntRadix", GoStr("zzzzzzzzzzzzzzzzzzzz"), Int(36)), 0, false)
	wantPanic(t, "radix out of range", "parseIntRadix", GoStr("zzz"), Int(1))
	wantPanic(t, "radix out of range", "parseIntRadix", GoStr("!"), Int(37))
}

// SPEC 17 example 8.
func TestExample8(t *testing.T) {
	wantStr(t, call("showInt", Int(math.MaxInt64+0)), "9223372036854775807")
	wantStr(t, call("strCat", call("showInt", call("divFloor", Int(-7), Int(2))), GoStr(" 1")), "-4 1")
	wantStr(t, call("showInt", call("powI", Int(3), Int(20))), "3486784401")
	wantInt(t, call("popCount", Int(255)), 8)
	wantInt(t, call("unwrapOr", call("parseInt", GoStr("-0042")), Int(0)), -42)
	wantBool(t, Bool(call("parseInt", GoStr("x")).P == NoneV.P), true)
}
