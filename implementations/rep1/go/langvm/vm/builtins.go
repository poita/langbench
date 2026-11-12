package vm

import (
	"math"
	"math/bits"

	"langvm/builtins"
	"langvm/numfmt"
)

type builtinFn func(v *VM, a []Value) Value

// builtinTable is indexed by built-in id (see package builtins).
var builtinTable []builtinFn

func init() {
	builtinTable = make([]builtinFn, len(builtins.All))
	for i, s := range builtins.All {
		f, ok := impls[s.Name]
		if !ok {
			panic("vm: missing implementation of built-in " + s.Name)
		}
		builtinTable[i] = f
	}
}

func str(x Value) []rune  { return x.([]rune) }
func i64(x Value) int64   { return x.(int64) }
func f64(x Value) float64 { return x.(float64) }

func fromString(s string) Value { return []rune(s) }

func cmpInt(a, b int64) int64 {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// cmpFloat implements cmpF: NaN sorts last.
func cmpFloat(a, b float64) int64 {
	an, bn := math.IsNaN(a), math.IsNaN(b)
	switch {
	case an && bn:
		return 0
	case an:
		return 1
	case bn:
		return -1
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func isSpaceRune(c rune) bool { return c == ' ' || (c >= 9 && c <= 13) }
func isDigitRune(c rune) bool { return c >= '0' && c <= '9' }
func isUpperRune(c rune) bool { return c >= 'A' && c <= 'Z' }
func isLowerRune(c rune) bool { return c >= 'a' && c <= 'z' }
func isAlphaRune(c rune) bool { return isUpperRune(c) || isLowerRune(c) }

func upperRune(c rune) rune {
	if isLowerRune(c) {
		return c - 32
	}
	return c
}

func lowerRune(c rune) rune {
	if isUpperRune(c) {
		return c + 32
	}
	return c
}

func escapeRunes(s []rune, quote rune) []rune {
	out := make([]rune, 0, len(s)+2)
	out = append(out, quote)
	hex := func(c rune) {
		out = append(out, '\\', 'u', '{')
		out = append(out, []rune(numfmt.FormatIntRadix(int64(c), 16))...)
		out = append(out, '}')
	}
	for _, c := range s {
		switch {
		case c == '\\':
			out = append(out, '\\', '\\')
		case c == quote:
			out = append(out, '\\', quote)
		case c == '\n':
			out = append(out, '\\', 'n')
		case c == '\r':
			out = append(out, '\\', 'r')
		case c == '\t':
			out = append(out, '\\', 't')
		case c < 0x20 || c == 0x7f:
			hex(c)
		default:
			out = append(out, c)
		}
	}
	return append(out, quote)
}

func indexOf(s, sub []rune, from int) int {
	n, m := len(s), len(sub)
	for i := from; i+m <= n; i++ {
		j := 0
		for j < m && s[i+j] == sub[j] {
			j++
		}
		if j == m {
			return i
		}
	}
	return -1
}

func hasPrefixAt(s, sub []rune, i int) bool {
	if i < 0 || i+len(sub) > len(s) {
		return false
	}
	for j := range sub {
		if s[i+j] != sub[j] {
			return false
		}
	}
	return true
}

func (v *VM) checkIndex(i int64, n int) {
	if i < 0 || i >= int64(n) {
		v.panicf("index out of bounds")
	}
}

func (v *VM) pad(a []Value, left bool) Value {
	s, w, c := str(a[0]), i64(a[1]), a[2].(rune)
	if w < 0 {
		v.panicf("negative count")
	}
	if int64(len(s)) >= w {
		return s
	}
	n := int(w) - len(s)
	out := make([]rune, 0, int(w))
	if !left {
		out = append(out, s...)
	}
	for i := 0; i < n; i++ {
		out = append(out, c)
	}
	if left {
		out = append(out, s...)
	}
	return out
}

func listOf(x Value) *List { return x.(*List) }

func (v *VM) sortBy(a []Value) Value {
	xs := listOf(a[0])
	cmp := a[1].(*Closure)
	n := len(xs.Elems)
	src := make([]Value, n)
	copy(src, xs.Elems)
	if n <= 1 {
		return newList(src)
	}
	dst := make([]Value, n)
	for width := 1; width < n; width *= 2 {
		for i := 0; i < n; i += 2 * width {
			lo := i
			mid := min(i+width, n)
			hi := min(i+2*width, n)
			x, y, k := lo, mid, lo
			for x < mid && y < hi {
				if i64(v.callClosure(cmp, src[x], src[y])) <= 0 {
					dst[k] = src[x]
					x++
				} else {
					dst[k] = src[y]
					y++
				}
				k++
			}
			for x < mid {
				dst[k] = src[x]
				x++
				k++
			}
			for y < hi {
				dst[k] = src[y]
				y++
				k++
			}
		}
		src, dst = dst, src
	}
	return newList(src)
}

func (v *VM) format(a []Value) Value {
	t := str(a[0])
	args := listOf(a[1]).Elems
	out := make([]rune, 0, len(t)+16)
	count := 0
	for i := 0; i < len(t); i++ {
		c := t[i]
		switch c {
		case '{':
			if i+1 >= len(t) {
				v.panicf("bad format")
			}
			switch t[i+1] {
			case '{':
				out = append(out, '{')
				i++
			case '}':
				if count < len(args) {
					out = append(out, str(args[count])...)
				}
				count++
				i++
			default:
				v.panicf("bad format")
			}
		case '}':
			if i+1 < len(t) && t[i+1] == '}' {
				out = append(out, '}')
				i++
			} else {
				v.panicf("bad format")
			}
		default:
			out = append(out, c)
		}
	}
	if count != len(args) {
		v.panicf("bad format")
	}
	return out
}

func (v *VM) powF(x float64, n int64) float64 {
	if n == math.MinInt64 {
		v.panicf("negative exponent")
	}
	neg := n < 0
	if neg {
		n = -n
	}
	r := 1.0
	b := x
	k := n
	for k > 0 {
		if k&1 == 1 {
			r = r * b
		}
		k >>= 1
		if k > 0 {
			b = b * b
		}
	}
	if neg {
		return 1.0 / r
	}
	return r
}

func (v *VM) divFloor(a, b int64) int64 {
	if b == 0 {
		v.panicf("divide by zero")
	}
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func (v *VM) modFloor(a, b int64) int64 {
	if b == 0 {
		v.panicf("modulo by zero")
	}
	r := a % b
	if r != 0 && (r < 0) != (b < 0) {
		r += b
	}
	return r
}

func gcd(a, b uint64) uint64 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

func absU(x int64) uint64 {
	if x < 0 {
		return uint64(-x)
	}
	return uint64(x)
}

func (v *VM) radix(r int64) int {
	if r < 2 || r > 36 {
		v.panicf("radix out of range")
	}
	return int(r)
}

func optInt(x int64, ok bool) Value {
	if !ok {
		return noneValue
	}
	return some(x)
}

func (v *VM) strSplit(s, sep []rune) Value {
	if len(sep) == 0 {
		v.panicf("empty separator")
	}
	var parts []Value
	start := 0
	i := 0
	for i+len(sep) <= len(s) {
		if hasPrefixAt(s, sep, i) {
			parts = append(parts, append([]rune{}, s[start:i]...))
			i += len(sep)
			start = i
		} else {
			i++
		}
	}
	parts = append(parts, append([]rune{}, s[start:]...))
	return newList(parts)
}

func (v *VM) strReplace(s, from, to []rune) Value {
	if len(from) == 0 {
		v.panicf("empty separator")
	}
	out := make([]rune, 0, len(s))
	i := 0
	for i < len(s) {
		if hasPrefixAt(s, from, i) {
			out = append(out, to...)
			i += len(from)
		} else {
			out = append(out, s[i])
			i++
		}
	}
	return out
}

func trimRunes(s []rune, left, right bool) []rune {
	i, j := 0, len(s)
	if left {
		for i < j && isSpaceRune(s[i]) {
			i++
		}
	}
	if right {
		for j > i && isSpaceRune(s[j-1]) {
			j--
		}
	}
	return append([]rune{}, s[i:j]...)
}

func mapOf(x Value) *Map { return x.(*Map) }

func enumOf(x Value) *Enum { return x.(*Enum) }

var impls = map[string]builtinFn{
	"print": func(v *VM, a []Value) Value {
		v.out.WriteString(string(str(a[0])))
		v.out.WriteByte('\n')
		return unit
	},
	"emit": func(v *VM, a []Value) Value {
		v.out.WriteString(string(str(a[0])))
		return unit
	},
	"panic": func(v *VM, a []Value) Value {
		v.panicf(string(str(a[0])))
		return unit
	},

	"intMin": func(v *VM, a []Value) Value { return int64(math.MinInt64) },
	"intMax": func(v *VM, a []Value) Value { return int64(math.MaxInt64) },
	"absI": func(v *VM, a []Value) Value {
		x := i64(a[0])
		if x < 0 {
			x = -x
		}
		return x
	},
	"minI":     func(v *VM, a []Value) Value { return min(i64(a[0]), i64(a[1])) },
	"maxI":     func(v *VM, a []Value) Value { return max(i64(a[0]), i64(a[1])) },
	"signI":    func(v *VM, a []Value) Value { return cmpInt(i64(a[0]), 0) },
	"cmpI":     func(v *VM, a []Value) Value { return cmpInt(i64(a[0]), i64(a[1])) },
	"divFloor": func(v *VM, a []Value) Value { return v.divFloor(i64(a[0]), i64(a[1])) },
	"modFloor": func(v *VM, a []Value) Value { return v.modFloor(i64(a[0]), i64(a[1])) },
	"powI": func(v *VM, a []Value) Value {
		base, e := i64(a[0]), i64(a[1])
		if e < 0 {
			v.panicf("negative exponent")
		}
		r := int64(1)
		for e > 0 {
			if e&1 == 1 {
				r *= base
			}
			base *= base
			e >>= 1
		}
		return r
	},
	"gcdI": func(v *VM, a []Value) Value {
		return int64(gcd(absU(i64(a[0])), absU(i64(a[1]))))
	},
	"popCount": func(v *VM, a []Value) Value { return int64(bits.OnesCount64(uint64(i64(a[0])))) },
	"clz":      func(v *VM, a []Value) Value { return int64(bits.LeadingZeros64(uint64(i64(a[0])))) },
	"ctz":      func(v *VM, a []Value) Value { return int64(bits.TrailingZeros64(uint64(i64(a[0])))) },
	"toFloat":  func(v *VM, a []Value) Value { return float64(i64(a[0])) },
	"showInt": func(v *VM, a []Value) Value {
		return fromString(numfmt.FormatIntRadix(i64(a[0]), 10))
	},
	"showIntRadix": func(v *VM, a []Value) Value {
		r := v.radix(i64(a[1]))
		return fromString(numfmt.FormatIntRadix(i64(a[0]), r))
	},
	"parseInt": func(v *VM, a []Value) Value {
		return optInt(numfmt.ParseIntRadix(str(a[0]), 10))
	},
	"parseIntRadix": func(v *VM, a []Value) Value {
		r := v.radix(i64(a[1]))
		return optInt(numfmt.ParseIntRadix(str(a[0]), r))
	},

	"sqrtF":  func(v *VM, a []Value) Value { return math.Sqrt(f64(a[0])) },
	"absF":   func(v *VM, a []Value) Value { return math.Abs(f64(a[0])) },
	"floorF": func(v *VM, a []Value) Value { return math.Floor(f64(a[0])) },
	"ceilF":  func(v *VM, a []Value) Value { return math.Ceil(f64(a[0])) },
	"truncF": func(v *VM, a []Value) Value { return math.Trunc(f64(a[0])) },
	"roundF": func(v *VM, a []Value) Value { return math.Round(f64(a[0])) },
	"minF": func(v *VM, a []Value) Value {
		if cmpFloat(f64(a[0]), f64(a[1])) <= 0 {
			return a[0]
		}
		return a[1]
	},
	"maxF": func(v *VM, a []Value) Value {
		if cmpFloat(f64(a[0]), f64(a[1])) >= 0 {
			return a[0]
		}
		return a[1]
	},
	"fmodF":  func(v *VM, a []Value) Value { return math.Mod(f64(a[0]), f64(a[1])) },
	"powF":   func(v *VM, a []Value) Value { return v.powF(f64(a[0]), i64(a[1])) },
	"isNanF": func(v *VM, a []Value) Value { return math.IsNaN(f64(a[0])) },
	"isInfF": func(v *VM, a []Value) Value { return math.IsInf(f64(a[0]), 0) },
	"cmpF":   func(v *VM, a []Value) Value { return cmpFloat(f64(a[0]), f64(a[1])) },
	"truncToInt": func(v *VM, a []Value) Value {
		x := f64(a[0])
		if math.IsNaN(x) || math.IsInf(x, 0) {
			v.panicf("float out of integer range")
		}
		t := math.Trunc(x)
		if t >= 9223372036854775808.0 || t < -9223372036854775808.0 {
			v.panicf("float out of integer range")
		}
		return int64(t)
	},
	"showFloat": func(v *VM, a []Value) Value { return fromString(numfmt.FormatFloatAt(f64(a[0]), 6)) },
	"showFloatAt": func(v *VM, a []Value) Value {
		d := i64(a[1])
		if d < 0 || d > 17 {
			v.panicf("digits out of range")
		}
		return fromString(numfmt.FormatFloatAt(f64(a[0]), int(d)))
	},
	"floatBits":     func(v *VM, a []Value) Value { return int64(math.Float64bits(f64(a[0]))) },
	"floatFromBits": func(v *VM, a []Value) Value { return math.Float64frombits(uint64(i64(a[0]))) },
	"parseFloat": func(v *VM, a []Value) Value {
		f, ok := numfmt.ParseFloat(str(a[0]))
		if !ok {
			return noneValue
		}
		return some(f)
	},
	"infF": func(v *VM, a []Value) Value { return math.Inf(1) },
	"nanF": func(v *VM, a []Value) Value { return math.Float64frombits(0x7ff8000000000000) },
	"piF":  func(v *VM, a []Value) Value { return math.Float64frombits(4614256656552045848) },

	"showBool": func(v *VM, a []Value) Value {
		if a[0].(bool) {
			return fromString("true")
		}
		return fromString("false")
	},
	"ord": func(v *VM, a []Value) Value { return int64(a[0].(rune)) },
	"chr": func(v *VM, a []Value) Value {
		n := i64(a[0])
		if n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
			v.panicf("invalid char code")
		}
		return rune(n)
	},
	"isDigit":   func(v *VM, a []Value) Value { return isDigitRune(a[0].(rune)) },
	"isAlpha":   func(v *VM, a []Value) Value { return isAlphaRune(a[0].(rune)) },
	"isAlnum":   func(v *VM, a []Value) Value { c := a[0].(rune); return isDigitRune(c) || isAlphaRune(c) },
	"isSpace":   func(v *VM, a []Value) Value { return isSpaceRune(a[0].(rune)) },
	"isUpper":   func(v *VM, a []Value) Value { return isUpperRune(a[0].(rune)) },
	"isLower":   func(v *VM, a []Value) Value { return isLowerRune(a[0].(rune)) },
	"toUpperC":  func(v *VM, a []Value) Value { return upperRune(a[0].(rune)) },
	"toLowerC":  func(v *VM, a []Value) Value { return lowerRune(a[0].(rune)) },
	"cmpC":      func(v *VM, a []Value) Value { return cmpInt(int64(a[0].(rune)), int64(a[1].(rune))) },
	"showChar":  func(v *VM, a []Value) Value { return []rune{a[0].(rune)} },
	"quoteChar": func(v *VM, a []Value) Value { return escapeRunes([]rune{a[0].(rune)}, '\'') },

	"strLen": func(v *VM, a []Value) Value { return int64(len(str(a[0]))) },
	"charAt": func(v *VM, a []Value) Value {
		s := str(a[0])
		i := i64(a[1])
		v.checkIndex(i, len(s))
		return s[i]
	},
	"substr": func(v *VM, a []Value) Value {
		s := str(a[0])
		from, to := i64(a[1]), i64(a[2])
		if from < 0 || from > to || to > int64(len(s)) {
			v.panicf("index out of bounds")
		}
		return append([]rune{}, s[from:to]...)
	},
	"strCat": func(v *VM, a []Value) Value {
		x, y := str(a[0]), str(a[1])
		r := make([]rune, 0, len(x)+len(y))
		return append(append(r, x...), y...)
	},
	"strRepeat": func(v *VM, a []Value) Value {
		s, n := str(a[0]), i64(a[1])
		if n < 0 {
			v.panicf("negative count")
		}
		r := make([]rune, 0, len(s)*int(n))
		for i := int64(0); i < n; i++ {
			r = append(r, s...)
		}
		return r
	},
	"strIndexOf": func(v *VM, a []Value) Value { return int64(indexOf(str(a[0]), str(a[1]), 0)) },
	"strLastIndexOf": func(v *VM, a []Value) Value {
		s, sub := str(a[0]), str(a[1])
		for i := len(s) - len(sub); i >= 0; i-- {
			if hasPrefixAt(s, sub, i) {
				return int64(i)
			}
		}
		return int64(-1)
	},
	"strContains": func(v *VM, a []Value) Value { return indexOf(str(a[0]), str(a[1]), 0) >= 0 },
	"startsWith":  func(v *VM, a []Value) Value { return hasPrefixAt(str(a[0]), str(a[1]), 0) },
	"endsWith": func(v *VM, a []Value) Value {
		s, p := str(a[0]), str(a[1])
		return hasPrefixAt(s, p, len(s)-len(p))
	},
	"strSplit": func(v *VM, a []Value) Value { return v.strSplit(str(a[0]), str(a[1])) },
	"strJoin": func(v *VM, a []Value) Value {
		parts := listOf(a[0]).Elems
		sep := str(a[1])
		var r []rune
		for i, p := range parts {
			if i > 0 {
				r = append(r, sep...)
			}
			r = append(r, str(p)...)
		}
		if r == nil {
			r = []rune{}
		}
		return r
	},
	"strReplace": func(v *VM, a []Value) Value { return v.strReplace(str(a[0]), str(a[1]), str(a[2])) },
	"trim":       func(v *VM, a []Value) Value { return trimRunes(str(a[0]), true, true) },
	"trimLeft":   func(v *VM, a []Value) Value { return trimRunes(str(a[0]), true, false) },
	"trimRight":  func(v *VM, a []Value) Value { return trimRunes(str(a[0]), false, true) },
	"upper": func(v *VM, a []Value) Value {
		s := str(a[0])
		r := make([]rune, len(s))
		for i, c := range s {
			r[i] = upperRune(c)
		}
		return r
	},
	"lower": func(v *VM, a []Value) Value {
		s := str(a[0])
		r := make([]rune, len(s))
		for i, c := range s {
			r[i] = lowerRune(c)
		}
		return r
	},
	"strCmp": func(v *VM, a []Value) Value { return int64(cmpRunes(str(a[0]), str(a[1]))) },
	"chars": func(v *VM, a []Value) Value {
		s := str(a[0])
		e := make([]Value, len(s))
		for i, c := range s {
			e[i] = c
		}
		return newList(e)
	},
	"strOfChars": func(v *VM, a []Value) Value {
		cs := listOf(a[0]).Elems
		r := make([]rune, len(cs))
		for i, c := range cs {
			r[i] = c.(rune)
		}
		return r
	},
	"strReverse": func(v *VM, a []Value) Value {
		s := str(a[0])
		r := make([]rune, len(s))
		for i, c := range s {
			r[len(s)-1-i] = c
		}
		return r
	},
	"quoteStr": func(v *VM, a []Value) Value { return escapeRunes(str(a[0]), '"') },
	"padLeft":  func(v *VM, a []Value) Value { return v.pad(a, true) },
	"padRight": func(v *VM, a []Value) Value { return v.pad(a, false) },

	"listNew": func(v *VM, a []Value) Value { return newList(nil) },
	"listLen": func(v *VM, a []Value) Value { return int64(len(listOf(a[0]).Elems)) },
	"push": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		l.Elems = append(l.Elems, a[1])
		return unit
	},
	"pop": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		n := len(l.Elems)
		if n == 0 {
			v.panicf("empty list")
		}
		x := l.Elems[n-1]
		l.Elems[n-1] = nil
		l.Elems = l.Elems[:n-1]
		return x
	},
	"insert": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		i := i64(a[1])
		if i < 0 || i > int64(len(l.Elems)) {
			v.panicf("index out of bounds")
		}
		l.Elems = append(l.Elems, nil)
		copy(l.Elems[i+1:], l.Elems[i:])
		l.Elems[i] = a[2]
		return unit
	},
	"removeAt": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		i := i64(a[1])
		v.checkIndex(i, len(l.Elems))
		x := l.Elems[i]
		copy(l.Elems[i:], l.Elems[i+1:])
		l.Elems[len(l.Elems)-1] = nil
		l.Elems = l.Elems[:len(l.Elems)-1]
		return x
	},
	"clear": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		l.Elems = nil
		return unit
	},
	"listRepeat": func(v *VM, a []Value) Value {
		n := i64(a[1])
		if n < 0 {
			v.panicf("negative count")
		}
		e := make([]Value, n)
		for i := range e {
			e[i] = a[0]
		}
		return newList(e)
	},
	"listConcat": func(v *VM, a []Value) Value {
		x, y := listOf(a[0]).Elems, listOf(a[1]).Elems
		r := make([]Value, 0, len(x)+len(y))
		return newList(append(append(r, x...), y...))
	},
	"slice": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		from, to := i64(a[1]), i64(a[2])
		if from < 0 || from > to || to > int64(len(l.Elems)) {
			v.panicf("index out of bounds")
		}
		return newList(append([]Value{}, l.Elems[from:to]...))
	},
	"listCopy": func(v *VM, a []Value) Value {
		return newList(append([]Value{}, listOf(a[0]).Elems...))
	},
	"reverseList": func(v *VM, a []Value) Value {
		x := listOf(a[0]).Elems
		r := make([]Value, len(x))
		for i, e := range x {
			r[len(x)-1-i] = e
		}
		return newList(r)
	},
	"listFirst": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		if len(l.Elems) == 0 {
			v.panicf("empty list")
		}
		return l.Elems[0]
	},
	"listLast": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		if len(l.Elems) == 0 {
			v.panicf("empty list")
		}
		return l.Elems[len(l.Elems)-1]
	},
	"listMap": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		var out []Value
		for i := 0; i < len(l.Elems); i++ {
			out = append(out, v.callClosure(f, l.Elems[i]))
		}
		return newList(out)
	},
	"listFilter": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		var out []Value
		for i := 0; i < len(l.Elems); i++ {
			x := l.Elems[i]
			if v.callClosure(f, x).(bool) {
				out = append(out, x)
			}
		}
		return newList(out)
	},
	"listFold": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		acc := a[1]
		f := a[2].(*Closure)
		for i := 0; i < len(l.Elems); i++ {
			acc = v.callClosure(f, acc, l.Elems[i])
		}
		return acc
	},
	"listAny": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		for i := 0; i < len(l.Elems); i++ {
			if v.callClosure(f, l.Elems[i]).(bool) {
				return true
			}
		}
		return false
	},
	"listAll": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		for i := 0; i < len(l.Elems); i++ {
			if !v.callClosure(f, l.Elems[i]).(bool) {
				return false
			}
		}
		return true
	},
	"listFind": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		for i := 0; i < len(l.Elems); i++ {
			x := l.Elems[i]
			if v.callClosure(f, x).(bool) {
				return some(x)
			}
		}
		return noneValue
	},
	"listFindIndex": func(v *VM, a []Value) Value {
		l := listOf(a[0])
		f := a[1].(*Closure)
		for i := 0; i < len(l.Elems); i++ {
			if v.callClosure(f, l.Elems[i]).(bool) {
				return int64(i)
			}
		}
		return int64(-1)
	},
	"listIndexOf": func(v *VM, a []Value) Value {
		for i, e := range listOf(a[0]).Elems {
			if equal(e, a[1]) {
				return int64(i)
			}
		}
		return int64(-1)
	},
	"listContains": func(v *VM, a []Value) Value {
		for _, e := range listOf(a[0]).Elems {
			if equal(e, a[1]) {
				return true
			}
		}
		return false
	},
	"listZip": func(v *VM, a []Value) Value {
		x, y := listOf(a[0]).Elems, listOf(a[1]).Elems
		n := min(len(x), len(y))
		r := make([]Value, n)
		for i := 0; i < n; i++ {
			r[i] = &Tuple{E: []Value{x[i], y[i]}}
		}
		return newList(r)
	},
	"listFlatten": func(v *VM, a []Value) Value {
		var r []Value
		for _, in := range listOf(a[0]).Elems {
			r = append(r, listOf(in).Elems...)
		}
		return newList(r)
	},
	"sortBy": func(v *VM, a []Value) Value { return v.sortBy(a) },

	"mapNew": func(v *VM, a []Value) Value { return newMap() },
	"mapLen": func(v *VM, a []Value) Value { return int64(mapOf(a[0]).live) },
	"mapHas": func(v *VM, a []Value) Value { _, ok := mapOf(a[0]).get(a[1]); return ok },
	"mapGet": func(v *VM, a []Value) Value {
		if x, ok := mapOf(a[0]).get(a[1]); ok {
			return some(x)
		}
		return noneValue
	},
	"mapGetOr": func(v *VM, a []Value) Value {
		if x, ok := mapOf(a[0]).get(a[1]); ok {
			return x
		}
		return a[2]
	},
	"mapSet": func(v *VM, a []Value) Value { mapOf(a[0]).set(a[1], a[2]); return unit },
	"mapDel": func(v *VM, a []Value) Value { return mapOf(a[0]).del(a[1]) },
	"keysOf": func(v *VM, a []Value) Value {
		m := mapOf(a[0])
		r := make([]Value, 0, m.live)
		for _, e := range m.entries {
			if !e.dead {
				r = append(r, e.key)
			}
		}
		return newList(r)
	},
	"valuesOf": func(v *VM, a []Value) Value {
		m := mapOf(a[0])
		r := make([]Value, 0, m.live)
		for _, e := range m.entries {
			if !e.dead {
				r = append(r, e.val)
			}
		}
		return newList(r)
	},
	"pairsOf": func(v *VM, a []Value) Value {
		m := mapOf(a[0])
		r := make([]Value, 0, m.live)
		for _, e := range m.entries {
			if !e.dead {
				r = append(r, &Tuple{E: []Value{e.key, e.val}})
			}
		}
		return newList(r)
	},
	"mapClear": func(v *VM, a []Value) Value { mapOf(a[0]).clear(); return unit },
	"mapCopy":  func(v *VM, a []Value) Value { return mapOf(a[0]).copyMap() },

	"isSome": func(v *VM, a []Value) Value { return enumOf(a[0]).Variant == someVar },
	"isNone": func(v *VM, a []Value) Value { return enumOf(a[0]).Variant == noneVar },
	"unwrap": func(v *VM, a []Value) Value {
		e := enumOf(a[0])
		if e.Variant == noneVar {
			v.panicf("unwrap of None")
		}
		return e.P[0]
	},
	"unwrapOr": func(v *VM, a []Value) Value {
		e := enumOf(a[0])
		if e.Variant == noneVar {
			return a[1]
		}
		return e.P[0]
	},
	"isOk":  func(v *VM, a []Value) Value { return enumOf(a[0]).Variant == okVar },
	"isErr": func(v *VM, a []Value) Value { return enumOf(a[0]).Variant == errVar },
	"unwrapOk": func(v *VM, a []Value) Value {
		e := enumOf(a[0])
		if e.Variant == errVar {
			v.panicf("unwrap of Err")
		}
		return e.P[0]
	},
	"unwrapErr": func(v *VM, a []Value) Value {
		e := enumOf(a[0])
		if e.Variant == okVar {
			v.panicf("unwrap of Ok")
		}
		return e.P[0]
	},
	"fst": func(v *VM, a []Value) Value { return a[0].(*Tuple).E[0] },
	"snd": func(v *VM, a []Value) Value { return a[0].(*Tuple).E[1] },

	"fmt": func(v *VM, a []Value) Value { return v.format(a) },
}
