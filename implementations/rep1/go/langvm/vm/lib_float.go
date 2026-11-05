package vm

import "math"

func init() {
	register("sqrtF", func(m *VM, a []Value) Value { return Float(math.Sqrt(a[0].F())) })
	register("absF", func(m *VM, a []Value) Value { return Float(math.Abs(a[0].F())) })
	register("floorF", func(m *VM, a []Value) Value { return Float(math.Floor(a[0].F())) })
	register("ceilF", func(m *VM, a []Value) Value { return Float(math.Ceil(a[0].F())) })
	register("truncF", func(m *VM, a []Value) Value { return Float(math.Trunc(a[0].F())) })
	register("roundF", func(m *VM, a []Value) Value { return Float(math.Round(a[0].F())) })
	register("minF", func(m *VM, a []Value) Value {
		if cmpFloat(a[0].F(), a[1].F()) <= 0 {
			return a[0]
		}
		return a[1]
	})
	register("maxF", func(m *VM, a []Value) Value {
		if cmpFloat(a[0].F(), a[1].F()) >= 0 {
			return a[0]
		}
		return a[1]
	})
	register("fmodF", func(m *VM, a []Value) Value { return Float(fmodFloat(a[0].F(), a[1].F())) })
	register("powF", func(m *VM, a []Value) Value {
		x, n := a[0].F(), a[1].N
		if n == math.MinInt64 {
			m.Panic("negative exponent")
		}
		if n < 0 {
			p := powFloat(x, -n)
			return Float(1.0 / p)
		}
		return Float(powFloat(x, n))
	})
	register("isNanF", func(m *VM, a []Value) Value { x := a[0].F(); return Bool(x != x) })
	register("isInfF", func(m *VM, a []Value) Value { return Bool(math.IsInf(a[0].F(), 0)) })
	register("cmpF", func(m *VM, a []Value) Value { return Int(int64(cmpFloat(a[0].F(), a[1].F()))) })
	register("truncToInt", func(m *VM, a []Value) Value {
		x := a[0].F()
		if x != x || math.IsInf(x, 0) {
			m.Panic("float out of integer range")
		}
		t := math.Trunc(x)
		if t >= 9223372036854775808.0 || t < -9223372036854775808.0 {
			m.Panic("float out of integer range")
		}
		return Int(int64(t))
	})
	register("showFloat", func(m *VM, a []Value) Value { return Str(formatFixed(a[0].F(), 6)) })
	register("showFloatAt", func(m *VM, a []Value) Value {
		d := a[1].N
		if d < 0 || d > 17 {
			m.Panic("digits out of range")
		}
		return Str(formatFixed(a[0].F(), int(d)))
	})
	register("floatBits", func(m *VM, a []Value) Value { return Int(a[0].N) })
	register("floatFromBits", func(m *VM, a []Value) Value { return Value{N: a[0].N, P: tagFloat} })
	register("parseFloat", func(m *VM, a []Value) Value {
		if f, ok := parseFloatRunes(a[0].P.S); ok {
			return Some(Float(f))
		}
		return NoneV
	})
	register("infF", func(m *VM, a []Value) Value { return Float(math.Inf(1)) })
	register("nanF", func(m *VM, a []Value) Value { return Value{N: 0x7ff8000000000000, P: tagFloat} })
	register("piF", func(m *VM, a []Value) Value { return Value{N: 4614256656552045848, P: tagFloat} })
}

// cmpFloat is cmpF: IEEE order with NaN sorting last.
func cmpFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	case a == b:
		return 0
	}
	an, bn := a != a, b != b
	switch {
	case an && bn:
		return 0
	case an:
		return 1
	}
	return -1
}

func fmodFloat(a, b float64) float64 {
	if a != a || b != b || b == 0 || math.IsInf(a, 0) {
		return math.Float64frombits(0x7ff8000000000000)
	}
	if math.IsInf(b, 0) {
		return a
	}
	return math.Mod(a, b)
}

// powFloat is the exact multiplication loop of SPEC 15.3 for n >= 0.
func powFloat(x float64, n int64) float64 {
	r := 1.0
	b := x
	k := n
	for k > 0 {
		if k&1 == 1 {
			r = float64(r * b)
		}
		k >>= 1
		if k > 0 {
			b = float64(b * b)
		}
	}
	return r
}
