package tmpl

import (
	"math"
	"math/big"
	"strings"
)

type numKind uint8

const (
	numNone numKind = iota
	numInt
	numFloat
)

// toNum classifies v as a number. Booleans are integers.
func toNum(v Value) (int64, float64, numKind) {
	switch x := v.(type) {
	case int64:
		return x, 0, numInt
	case float64:
		return 0, x, numFloat
	case bool:
		return b2i(x), 0, numInt
	}
	return 0, 0, numNone
}

func asFloat(i int64, f float64, k numKind) float64 {
	if k == numInt {
		return float64(i)
	}
	return f
}

func floorDivInt(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func modInt(a, b int64) int64 {
	r := a % b
	if r != 0 && (r < 0) != (b < 0) {
		r += b
	}
	return r
}

func modFloat(a, b float64) float64 {
	r := math.Mod(a, b)
	if r != 0 && (r < 0) != (b < 0) {
		r += b
	}
	return r
}

func powInt(base, exp int64) int64 {
	result := int64(1)
	for exp > 0 {
		if exp&1 == 1 {
			result *= base
		}
		base *= base
		exp >>= 1
	}
	return result
}

// binaryOp applies an arithmetic operator to two defined values.
func binaryOp(op opcode, a, b Value) Value {
	ai, af, ak := toNum(a)
	bi, bf, bk := toNum(b)
	bothNum := ak != numNone && bk != numNone
	bothInt := ak == numInt && bk == numInt
	switch op {
	case opAdd:
		switch {
		case bothInt:
			return ai + bi
		case bothNum:
			return asFloat(ai, af, ak) + asFloat(bi, bf, bk)
		}
		switch x := a.(type) {
		case string:
			if y, ok := b.(string); ok {
				return x + y
			}
		case []Value:
			if y, ok := b.([]Value); ok {
				out := make([]Value, 0, len(x)+len(y))
				return append(append(out, x...), y...)
			}
		}
	case opSub:
		switch {
		case bothInt:
			return ai - bi
		case bothNum:
			return asFloat(ai, af, ak) - asFloat(bi, bf, bk)
		}
	case opMul:
		switch {
		case bothInt:
			return ai * bi
		case bothNum:
			return asFloat(ai, af, ak) * asFloat(bi, bf, bk)
		}
		if s, ok := a.(string); ok && bk == numInt {
			return repeat(s, bi)
		}
		if s, ok := b.(string); ok && ak == numInt {
			return repeat(s, ai)
		}
	case opDiv:
		if bothNum {
			d := asFloat(bi, bf, bk)
			if d == 0 {
				throw(KindType, "division by zero")
			}
			return asFloat(ai, af, ak) / d
		}
	case opFloorDiv:
		if bothInt {
			if bi == 0 {
				throw(KindType, "division by zero")
			}
			return floorDivInt(ai, bi)
		}
		if bothNum {
			d := asFloat(bi, bf, bk)
			if d == 0 {
				throw(KindType, "division by zero")
			}
			return math.Floor(asFloat(ai, af, ak) / d)
		}
	case opMod:
		if bothInt {
			if bi == 0 {
				throw(KindType, "modulo by zero")
			}
			return modInt(ai, bi)
		}
		if bothNum {
			d := asFloat(bi, bf, bk)
			if d == 0 {
				throw(KindType, "modulo by zero")
			}
			return modFloat(asFloat(ai, af, ak), d)
		}
	case opPow:
		if bothInt {
			if bi >= 0 {
				return powInt(ai, bi)
			}
			if ai == 0 {
				throw(KindType, "zero to a negative power")
			}
			return powFloat(float64(ai), float64(bi))
		}
		if bothNum {
			x, y := asFloat(ai, af, ak), asFloat(bi, bf, bk)
			if x == 0 && y < 0 {
				throw(KindType, "zero to a negative power")
			}
			return powFloat(x, y)
		}
	case opConcat:
		return toString(a) + toString(b)
	}
	throw(KindType, "unsupported operand types for the operator")
	return nil
}

func repeat(s string, n int64) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat(s, int(n))
}

// equal implements == on two defined values.
func equal(a, b Value) bool {
	switch x := a.(type) {
	case string:
		y, ok := b.(string)
		return ok && x == y
	case int64, float64, bool:
		ai, af, ak := toNum(a)
		bi, bf, bk := toNum(b)
		switch {
		case bk == numNone:
			return false
		case ak == numInt && bk == numInt:
			return ai == bi
		}
		return asFloat(ai, af, ak) == asFloat(bi, bf, bk)
	case noneType:
		_, ok := b.(noneType)
		return ok
	case []Value:
		y, ok := b.([]Value)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case *Dict:
		y, ok := b.(*Dict)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for k, v := range x.m {
			w, ok := y.m[k]
			if !ok || !equal(v, w) {
				return false
			}
		}
		return true
	}
	return false
}

// compareOp applies a comparison or membership operator to defined values.
func compareOp(op opcode, a, b Value) bool {
	switch op {
	case opEq:
		return equal(a, b)
	case opNe:
		return !equal(a, b)
	case opIn:
		return contains(b, a)
	case opNotIn:
		return !contains(b, a)
	}
	c := order(a, b)
	switch op {
	case opLt:
		return c < 0
	case opLe:
		return c <= 0
	case opGt:
		return c > 0
	}
	return c >= 0
}

// order compares two numbers or two strings, returning -1, 0 or 1.
func order(a, b Value) int {
	if x, ok := a.(string); ok {
		if y, ok := b.(string); ok {
			return strings.Compare(x, y)
		}
		throw(KindType, "cannot order a string and a non-string")
	}
	ai, af, ak := toNum(a)
	bi, bf, bk := toNum(b)
	if ak == numNone || bk == numNone {
		throw(KindType, "values cannot be ordered")
	}
	if ak == numInt && bk == numInt {
		switch {
		case ai < bi:
			return -1
		case ai > bi:
			return 1
		}
		return 0
	}
	x, y := asFloat(ai, af, ak), asFloat(bi, bf, bk)
	switch {
	case x < y:
		return -1
	case x > y:
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
			throw(KindType, "'in <string>' requires a string")
		}
		return strings.Contains(c, s)
	case *Dict:
		s, ok := item.(string)
		if !ok {
			return false
		}
		_, found := c.m[s]
		return found
	case []Value:
		for _, e := range c {
			if equal(e, item) {
				return true
			}
		}
		return false
	}
	throw(KindType, "argument of 'in' is not a container")
	return false
}

// powFloat computes x**y. Go's math.Pow is not correctly rounded, while the
// reference semantics use the C library's pow, so integral exponents of
// moderate size are computed in extended precision and rounded once.
func powFloat(x, y float64) float64 {
	if y != math.Trunc(y) || math.Abs(y) > 4096 || x == 0 || math.IsInf(x, 0) || math.IsNaN(x) {
		return math.Pow(x, y)
	}
	n := int(math.Abs(y))
	const prec = 256
	result := new(big.Float).SetPrec(prec).SetInt64(1)
	base := new(big.Float).SetPrec(prec).SetFloat64(x)
	for ; n > 0; n >>= 1 {
		if n&1 == 1 {
			result.Mul(result, base)
		}
		base.Mul(base, base)
	}
	if y < 0 {
		result.Quo(new(big.Float).SetPrec(prec).SetInt64(1), result)
	}
	f, _ := result.Float64()
	return f
}
