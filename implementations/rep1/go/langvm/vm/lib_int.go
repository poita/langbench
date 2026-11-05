package vm

import (
	"math"
	"math/bits"
)

func init() {
	register("intMin", func(m *VM, a []Value) Value { return Int(math.MinInt64) })
	register("intMax", func(m *VM, a []Value) Value { return Int(math.MaxInt64) })
	register("absI", func(m *VM, a []Value) Value {
		x := a[0].N
		if x < 0 {
			x = -x
		}
		return Int(x)
	})
	register("minI", func(m *VM, a []Value) Value {
		if a[1].N < a[0].N {
			return Int(a[1].N)
		}
		return Int(a[0].N)
	})
	register("maxI", func(m *VM, a []Value) Value {
		if a[1].N > a[0].N {
			return Int(a[1].N)
		}
		return Int(a[0].N)
	})
	register("signI", func(m *VM, a []Value) Value {
		x := a[0].N
		switch {
		case x < 0:
			return Int(-1)
		case x > 0:
			return Int(1)
		}
		return Int(0)
	})
	register("cmpI", func(m *VM, a []Value) Value { return Int(cmpInt(a[0].N, a[1].N)) })
	register("divFloor", func(m *VM, a []Value) Value {
		x, y := a[0].N, a[1].N
		if y == 0 {
			m.Panic("divide by zero")
		}
		return Int(divFloor(x, y))
	})
	register("modFloor", func(m *VM, a []Value) Value {
		x, y := a[0].N, a[1].N
		if y == 0 {
			m.Panic("modulo by zero")
		}
		if y == -1 {
			return Int(0)
		}
		r := x % y
		if r != 0 && (r < 0) != (y < 0) {
			r += y
		}
		return Int(r)
	})
	register("powI", func(m *VM, a []Value) Value {
		b, e := a[0].N, a[1].N
		if e < 0 {
			m.Panic("negative exponent")
		}
		r := int64(1)
		for e > 0 {
			if e&1 == 1 {
				r *= b
			}
			e >>= 1
			if e > 0 {
				b *= b
			}
		}
		return Int(r)
	})
	register("gcdI", func(m *VM, a []Value) Value {
		x, y := absU64(a[0].N), absU64(a[1].N)
		for y != 0 {
			x, y = y, x%y
		}
		return Int(int64(x))
	})
	register("popCount", func(m *VM, a []Value) Value { return Int(int64(bits.OnesCount64(uint64(a[0].N)))) })
	register("clz", func(m *VM, a []Value) Value { return Int(int64(bits.LeadingZeros64(uint64(a[0].N)))) })
	register("ctz", func(m *VM, a []Value) Value { return Int(int64(bits.TrailingZeros64(uint64(a[0].N)))) })
	register("toFloat", func(m *VM, a []Value) Value { return Float(float64(a[0].N)) })
	register("showInt", func(m *VM, a []Value) Value { return Str(intRunes(a[0].N)) })
	register("showIntRadix", func(m *VM, a []Value) Value {
		r := a[1].N
		if r < 2 || r > 36 {
			m.Panic("radix out of range")
		}
		return Str(radixRunes(a[0].N, int(r)))
	})
	register("parseInt", func(m *VM, a []Value) Value {
		if v, ok := parseIntRunes(a[0].P.S, 10); ok {
			return Some(Int(v))
		}
		return NoneV
	})
	register("parseIntRadix", func(m *VM, a []Value) Value {
		r := a[1].N
		if r < 2 || r > 36 {
			m.Panic("radix out of range")
		}
		if v, ok := parseIntRunes(a[0].P.S, int(r)); ok {
			return Some(Int(v))
		}
		return NoneV
	})
}

func cmpInt(a, b int64) int64 {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

func absU64(x int64) uint64 {
	if x < 0 {
		return -uint64(x)
	}
	return uint64(x)
}

// divFloor is floor division; y must be non-zero. intMin / -1 wraps.
func divFloor(x, y int64) int64 {
	if y == -1 {
		return -x
	}
	q := x / y
	if x%y != 0 && (x < 0) != (y < 0) {
		q--
	}
	return q
}

// intRunes renders x in decimal.
func intRunes(x int64) []rune {
	var buf [24]rune
	i := len(buf)
	u := absU64(x)
	if u == 0 {
		i--
		buf[i] = '0'
	}
	for u > 0 {
		i--
		buf[i] = rune('0' + u%10)
		u /= 10
	}
	if x < 0 {
		i--
		buf[i] = '-'
	}
	out := make([]rune, len(buf)-i)
	copy(out, buf[i:])
	return out
}

const digitChars = "0123456789abcdefghijklmnopqrstuvwxyz"

// radixRunes renders x in the given radix (2..36), using the unsigned
// magnitude.
func radixRunes(x int64, radix int) []rune {
	var buf [72]rune
	i := len(buf)
	u := absU64(x)
	r := uint64(radix)
	if u == 0 {
		i--
		buf[i] = '0'
	}
	for u > 0 {
		i--
		buf[i] = rune(digitChars[u%r])
		u /= r
	}
	if x < 0 {
		i--
		buf[i] = '-'
	}
	out := make([]rune, len(buf)-i)
	copy(out, buf[i:])
	return out
}

func digitVal(c rune) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'z':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'Z':
		return int(c-'A') + 10
	}
	return 99
}

// parseIntRunes implements the parseInt / parseIntRadix grammar.
func parseIntRunes(s []rune, radix int) (int64, bool) {
	i := 0
	neg := false
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		neg = s[0] == '-'
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	limit := uint64(math.MaxInt64)
	if neg {
		limit = uint64(1) << 63
	}
	r := uint64(radix)
	var acc uint64
	for ; i < len(s); i++ {
		d := uint64(digitVal(s[i]))
		if d >= r {
			return 0, false
		}
		hi, lo := bits.Mul64(acc, r)
		lo2, carry := bits.Add64(lo, d, 0)
		if hi != 0 || carry != 0 || lo2 > limit {
			return 0, false
		}
		acc = lo2
	}
	if neg {
		return int64(-acc), true
	}
	return int64(acc), true
}
