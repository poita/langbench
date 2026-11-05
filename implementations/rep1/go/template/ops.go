package template

import (
	"math"
	"strings"
	"unicode/utf8"
)

// checkDefined raises the undefined error if either operand is undefined.
func checkDefined(a, b Value) {
	if IsUndefined(a) || IsUndefined(b) {
		throw(ErrUndefined, "use of undefined value")
	}
}

func typeErr(op string, a, b Value) {
	throw(ErrType, "unsupported operand types for %s", op)
}

// binaryOp applies an arithmetic or concatenation operator.
func binaryOp(op binOp, a, b Value) Value {
	checkDefined(a, b)
	if op == opConcat {
		return toString(a) + toString(b)
	}
	ai, af, ak := num(a)
	bi, bf, bk := num(b)
	if ak != nkNone && bk != nkNone {
		return numericOp(op, ai, af, ak, bi, bf, bk)
	}
	switch op {
	case opAdd:
		switch x := a.(type) {
		case string:
			if y, ok := b.(string); ok {
				return x + y
			}
		case *List:
			if y, ok := b.(*List); ok {
				items := make([]Value, 0, len(x.Items)+len(y.Items))
				items = append(items, x.Items...)
				items = append(items, y.Items...)
				return &List{Items: items}
			}
		}
		typeErr("+", a, b)
	case opMul:
		if s, ok := a.(string); ok && bk == nkInt {
			return repeat(s, bi)
		}
		if s, ok := b.(string); ok && ak == nkInt {
			return repeat(s, ai)
		}
		typeErr("*", a, b)
	}
	typeErr("operator", a, b)
	return nil
}

func repeat(s string, n int64) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat(s, int(n))
}

func numericOp(op binOp, ai int64, af float64, ak numKind, bi int64, bf float64, bk numKind) Value {
	bothInt := ak == nkInt && bk == nkInt
	switch op {
	case opAdd:
		if bothInt {
			return ai + bi
		}
		return asFloat(ai, af, ak) + asFloat(bi, bf, bk)
	case opSub:
		if bothInt {
			return ai - bi
		}
		return asFloat(ai, af, ak) - asFloat(bi, bf, bk)
	case opMul:
		if bothInt {
			return ai * bi
		}
		return asFloat(ai, af, ak) * asFloat(bi, bf, bk)
	case opDiv:
		y := asFloat(bi, bf, bk)
		if y == 0 {
			throw(ErrType, "division by zero")
		}
		return asFloat(ai, af, ak) / y
	case opFloorDiv:
		if bothInt {
			if bi == 0 {
				throw(ErrType, "division by zero")
			}
			q := ai / bi
			if ai%bi != 0 && (ai < 0) != (bi < 0) {
				q--
			}
			return q
		}
		y := asFloat(bi, bf, bk)
		if y == 0 {
			throw(ErrType, "division by zero")
		}
		fd, _ := floatDivMod(asFloat(ai, af, ak), y)
		return fd
	case opMod:
		if bothInt {
			if bi == 0 {
				throw(ErrType, "modulo by zero")
			}
			r := ai % bi
			if r != 0 && (r < 0) != (bi < 0) {
				r += bi
			}
			return r
		}
		y := asFloat(bi, bf, bk)
		if y == 0 {
			throw(ErrType, "modulo by zero")
		}
		_, m := floatDivMod(asFloat(ai, af, ak), y)
		return m
	case opPow:
		if bothInt {
			if bi >= 0 {
				r := int64(1)
				for i := int64(0); i < bi; i++ {
					r *= ai
				}
				return r
			}
			if ai == 0 {
				throw(ErrType, "zero to a negative power")
			}
			return math.Pow(float64(ai), float64(bi))
		}
		x, y := asFloat(ai, af, ak), asFloat(bi, bf, bk)
		if x == 0 && y < 0 {
			throw(ErrType, "zero to a negative power")
		}
		return math.Pow(x, y)
	}
	throw(ErrType, "bad operator")
	return nil
}

// floatDivMod implements Python's float floor division and modulo.
func floatDivMod(x, y float64) (floordiv, mod float64) {
	mod = math.Mod(x, y)
	div := (x - mod) / y
	if mod != 0 {
		if (y < 0) != (mod < 0) {
			mod += y
			div--
		}
	} else {
		mod = math.Copysign(0, y)
	}
	if div != 0 {
		floordiv = math.Floor(div)
		if div-floordiv > 0.5 {
			floordiv++
		}
	} else {
		floordiv = math.Copysign(0, x/y)
	}
	return
}

// negate implements unary minus.
func negate(v Value) Value {
	switch x := v.(type) {
	case int64:
		return -x
	case float64:
		return -x
	case bool:
		if x {
			return int64(-1)
		}
		return int64(0)
	case undefinedType:
		throw(ErrUndefined, "use of undefined value")
	}
	throw(ErrType, "bad operand type for unary -")
	return nil
}

// compareOp implements one comparison operator between two evaluated
// operands.
func compareOp(op cmpOp, a, b Value) bool {
	checkDefined(a, b)
	switch op {
	case cmpEq:
		return valuesEqual(a, b)
	case cmpNe:
		return !valuesEqual(a, b)
	case cmpIn:
		return contains(b, a)
	case cmpNotIn:
		return !contains(b, a)
	}
	var c int
	ai, af, ak := num(a)
	bi, bf, bk := num(b)
	switch {
	case ak != nkNone && bk != nkNone:
		if ak == nkInt && bk == nkInt {
			c = cmp3(ai, bi)
		} else {
			x, y := asFloat(ai, af, ak), asFloat(bi, bf, bk)
			switch {
			case x < y:
				c = -1
			case x > y:
				c = 1
			}
		}
	default:
		s, ok1 := a.(string)
		t, ok2 := b.(string)
		if !ok1 || !ok2 {
			throw(ErrType, "values are not orderable")
		}
		c = strings.Compare(s, t)
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

func cmp3(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// contains implements "item in container".
func contains(container, item Value) bool {
	switch c := container.(type) {
	case string:
		s, ok := item.(string)
		if !ok {
			throw(ErrType, "'in <string>' requires a string")
		}
		return strings.Contains(c, s)
	case *Dict:
		s, ok := item.(string)
		if !ok {
			return false
		}
		_, found := c.Get(s)
		return found
	case *List:
		for _, e := range c.Items {
			if valuesEqual(e, item) {
				return true
			}
		}
		return false
	}
	throw(ErrType, "argument of 'in' is not a container")
	return false
}

// runeStringAt returns the code point at index i of s (negative counts from
// the end) as a string, or ok=false if out of range.
func runeIndex(s string, i int64) (string, bool) {
	if i < 0 {
		i += int64(utf8.RuneCountInString(s))
		if i < 0 {
			return "", false
		}
	}
	for pos := 0; pos < len(s); {
		_, size := utf8.DecodeRuneInString(s[pos:])
		if i == 0 {
			return s[pos : pos+size], true
		}
		i--
		pos += size
	}
	return "", false
}

// getItem implements a.NAME and a[key].
func getItem(a, key Value) Value {
	if IsUndefined(a) || IsUndefined(key) {
		throw(ErrUndefined, "attribute or subscript of undefined value")
	}
	switch x := a.(type) {
	case *Dict:
		if k, ok := key.(string); ok {
			if v, ok := x.Get(k); ok {
				return v
			}
		}
	case *List:
		if i, _, k := num(key); k == nkInt {
			if i < 0 {
				i += int64(len(x.Items))
			}
			if i >= 0 && i < int64(len(x.Items)) {
				return x.Items[i]
			}
		}
	case string:
		if i, _, k := num(key); k == nkInt {
			if s, ok := runeIndex(x, i); ok {
				return s
			}
		}
	case *loopRec:
		if k, ok := key.(string); ok {
			return x.get(k)
		}
	}
	return Undefined
}
