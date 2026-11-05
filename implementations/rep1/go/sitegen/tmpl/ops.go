package tmpl

import (
	"math"
	"strings"
	"unicode/utf8"
)

func checkDefined(vs ...Value) {
	for _, v := range vs {
		if IsUndefined(v) {
			fail(UndefinedError, "use of an undefined value")
		}
	}
}

func isFloat(v Value) bool { _, ok := v.(float64); return ok }

// binary evaluates an arithmetic or concatenation operator on defined values.
func binary(op binOp, a, b Value) Value {
	checkDefined(a, b)
	if op == opConcat {
		return toString(a) + toString(b)
	}
	an, bn := isNumber(a), isNumber(b)
	switch op {
	case opAdd:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				return toFloat(a) + toFloat(b)
			}
			return toInt64(a) + toInt64(b)
		}
		switch x := a.(type) {
		case string:
			if y, ok := b.(string); ok {
				return x + y
			}
		case List:
			if y, ok := b.(List); ok {
				out := make(List, 0, len(x)+len(y))
				return append(append(out, x...), y...)
			}
		}
		fail(TypeError, "unsupported operands for +")
	case opSub:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				return toFloat(a) - toFloat(b)
			}
			return toInt64(a) - toInt64(b)
		}
		fail(TypeError, "unsupported operands for -")
	case opMul:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				return toFloat(a) * toFloat(b)
			}
			return toInt64(a) * toInt64(b)
		}
		if s, ok := a.(string); ok && isIntLike(b) {
			return repeat(s, toInt64(b))
		}
		if s, ok := b.(string); ok && isIntLike(a) {
			return repeat(s, toInt64(a))
		}
		fail(TypeError, "unsupported operands for *")
	case opDiv:
		if an && bn {
			d := toFloat(b)
			if d == 0 {
				fail(TypeError, "division by zero")
			}
			return toFloat(a) / d
		}
		fail(TypeError, "unsupported operands for /")
	case opFloorDiv:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				d := toFloat(b)
				if d == 0 {
					fail(TypeError, "division by zero")
				}
				return math.Floor(toFloat(a) / d)
			}
			x, y := toInt64(a), toInt64(b)
			if y == 0 {
				fail(TypeError, "division by zero")
			}
			q := x / y
			if (x%y != 0) && ((x < 0) != (y < 0)) {
				q--
			}
			return q
		}
		fail(TypeError, "unsupported operands for //")
	case opMod:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				x, y := toFloat(a), toFloat(b)
				if y == 0 {
					fail(TypeError, "modulo by zero")
				}
				r := math.Mod(x, y)
				if r != 0 && (r < 0) != (y < 0) {
					r += y
				}
				return r
			}
			x, y := toInt64(a), toInt64(b)
			if y == 0 {
				fail(TypeError, "modulo by zero")
			}
			r := x % y
			if r != 0 && (r < 0) != (y < 0) {
				r += y
			}
			return r
		}
		fail(TypeError, "unsupported operands for %%")
	case opPow:
		if an && bn {
			if isFloat(a) || isFloat(b) {
				x, y := toFloat(a), toFloat(b)
				if x == 0 && y < 0 {
					fail(TypeError, "zero to a negative power")
				}
				return math.Pow(x, y)
			}
			x, y := toInt64(a), toInt64(b)
			if y < 0 {
				if x == 0 {
					fail(TypeError, "zero to a negative power")
				}
				return math.Pow(float64(x), float64(y))
			}
			result := int64(1)
			for ; y > 0; y-- {
				result *= x
			}
			return result
		}
		fail(TypeError, "unsupported operands for **")
	}
	return nil
}

func repeat(s string, n int64) string {
	if n <= 0 || s == "" {
		return ""
	}
	return strings.Repeat(s, int(n))
}

func negate(v Value) Value {
	checkDefined(v)
	switch x := v.(type) {
	case int64:
		return -x
	case float64:
		return -x
	case bool:
		return -toInt64(x)
	}
	fail(TypeError, "bad operand for unary -")
	return nil
}

// compare evaluates one comparison operator on two evaluated operands.
func compare(op cmpOp, a, b Value) bool {
	checkDefined(a, b)
	switch op {
	case cmpEq:
		return equals(a, b)
	case cmpNe:
		return !equals(a, b)
	case cmpIn, cmpNotIn:
		return contains(b, a) == (op == cmpIn)
	}
	var c int
	switch {
	case isNumber(a) && isNumber(b):
		if isFloat(a) || isFloat(b) {
			x, y := toFloat(a), toFloat(b)
			switch {
			case x < y:
				c = -1
			case x > y:
				c = 1
			}
		} else {
			x, y := toInt64(a), toInt64(b)
			switch {
			case x < y:
				c = -1
			case x > y:
				c = 1
			}
		}
	default:
		x, ok1 := a.(string)
		y, ok2 := b.(string)
		if !ok1 || !ok2 {
			fail(TypeError, "values cannot be ordered")
		}
		c = strings.Compare(x, y)
	}
	switch op {
	case cmpLt:
		return c < 0
	case cmpLe:
		return c <= 0
	case cmpGt:
		return c > 0
	}
	return c >= 0
}

// contains implements "needle in haystack".
func contains(haystack, needle Value) bool {
	switch h := haystack.(type) {
	case string:
		n, ok := needle.(string)
		if !ok {
			fail(TypeError, "'in <string>' requires a string")
		}
		return strings.Contains(h, n)
	case *Dict:
		n, ok := needle.(string)
		if !ok {
			return false
		}
		_, found := h.Get(n)
		return found
	case List:
		for _, e := range h {
			if equals(e, needle) {
				return true
			}
		}
		return false
	}
	fail(TypeError, "argument is not iterable")
	return false
}

// getItem implements a.NAME and a[key].
func getItem(obj, key Value) Value {
	checkDefined(obj, key)
	switch o := obj.(type) {
	case *Dict:
		if k, ok := key.(string); ok {
			if v, found := o.Get(k); found {
				return v
			}
		}
	case List:
		if isIntLike(key) {
			i := toInt64(key)
			if i < 0 {
				i += int64(len(o))
			}
			if i >= 0 && i < int64(len(o)) {
				return o[i]
			}
		}
	case string:
		if isIntLike(key) {
			return stringIndex(o, toInt64(key))
		}
	case *loopRec:
		if k, ok := key.(string); ok {
			return o.attr(k)
		}
	}
	return Undefined
}

func stringIndex(s string, i int64) Value {
	if i < 0 {
		i += int64(utf8.RuneCountInString(s))
		if i < 0 {
			return Undefined
		}
	}
	for pos := 0; pos < len(s); {
		_, n := utf8.DecodeRuneInString(s[pos:])
		if i == 0 {
			return s[pos : pos+n]
		}
		i--
		pos += n
	}
	return Undefined
}

// loopRec is the value of "loop" inside a for body. It is updated in place.
type loopRec struct {
	index  int // 0-based
	length int
}

func (l *loopRec) attr(k string) Value {
	switch k {
	case "index":
		return int64(l.index + 1)
	case "index0":
		return int64(l.index)
	case "first":
		return l.index == 0
	case "last":
		return l.index == l.length-1
	case "length":
		return int64(l.length)
	}
	return Undefined
}
