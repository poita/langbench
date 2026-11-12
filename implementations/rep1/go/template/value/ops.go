package value

import (
	"math"
	"strings"
	"unicode/utf8"
)

// Truthy reports the truthiness of v. The undefined value is an error.
func Truthy(v Value) (bool, error) {
	switch x := v.(type) {
	case bool:
		return x, nil
	case int64:
		return x != 0, nil
	case float64:
		return x != 0, nil
	case string:
		return x != "", nil
	case NoneType:
		return false, nil
	case *List:
		return len(x.Items) > 0, nil
	case *Dict:
		return x.Len() > 0, nil
	case UndefinedType:
		return false, undefinedError("truth value of the undefined value")
	}
	return true, nil
}

// number classifies v as a number (integer, float or boolean).
func number(v Value) (i int64, f float64, isFloat, ok bool) {
	switch x := v.(type) {
	case int64:
		return x, float64(x), false, true
	case float64:
		return 0, x, true, true
	case bool:
		if x {
			return 1, 1, false, true
		}
		return 0, 0, false, true
	}
	return 0, 0, false, false
}

// Seq returns the sequence view of v: a list's elements, a dict's keys, or a
// string's characters. Anything else is a type error (undefined: an
// undefined error). The returned slice must not be modified.
func Seq(v Value) ([]Value, error) {
	switch x := v.(type) {
	case *List:
		return x.Items, nil
	case *Dict:
		out := make([]Value, len(x.keys))
		for i, k := range x.keys {
			out[i] = k
		}
		return out, nil
	case string:
		out := make([]Value, 0, len(x))
		for i := 0; i < len(x); {
			_, w := utf8.DecodeRuneInString(x[i:])
			out = append(out, x[i:i+w])
			i += w
		}
		return out, nil
	case UndefinedType:
		return nil, undefinedError("iterating the undefined value")
	}
	return nil, typeError("value of type %T is not a sequence", v)
}

// Equal implements == for two defined values.
func Equal(a, b Value) bool {
	if ai, af, aFloat, ok := number(a); ok {
		bi, bf, bFloat, ok := number(b)
		if !ok {
			return false
		}
		if aFloat || bFloat {
			return af == bf
		}
		return ai == bi
	}
	switch x := a.(type) {
	case string:
		y, ok := b.(string)
		return ok && x == y
	case NoneType:
		_, ok := b.(NoneType)
		return ok
	case *List:
		y, ok := b.(*List)
		if !ok || len(x.Items) != len(y.Items) {
			return false
		}
		for i := range x.Items {
			if !Equal(x.Items[i], y.Items[i]) {
				return false
			}
		}
		return true
	case *Dict:
		y, ok := b.(*Dict)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for i, k := range x.keys {
			o, ok := y.Get(k)
			if !ok || !Equal(x.vals[i], o) {
				return false
			}
		}
		return true
	}
	return false
}

// CmpOp is a comparison operator.
type CmpOp int

// The comparison operators.
const (
	CmpEq CmpOp = iota
	CmpNe
	CmpLt
	CmpLe
	CmpGt
	CmpGe
	CmpIn
	CmpNotIn
)

// Compare applies a comparison operator to two evaluated operands.
func Compare(op CmpOp, a, b Value) (bool, error) {
	if IsUndefined(a) || IsUndefined(b) {
		return false, undefinedError("comparison with the undefined value")
	}
	switch op {
	case CmpEq:
		return Equal(a, b), nil
	case CmpNe:
		return !Equal(a, b), nil
	case CmpIn, CmpNotIn:
		r, err := Contains(b, a)
		return r == (op == CmpIn), err
	}
	c, err := Order(a, b)
	if err != nil {
		return false, err
	}
	switch op {
	case CmpLt:
		return c < 0, nil
	case CmpLe:
		return c <= 0, nil
	case CmpGt:
		return c > 0, nil
	}
	return c >= 0, nil
}

// Order compares two numbers or two strings, returning -1, 0 or 1. Other
// combinations are a type error.
func Order(a, b Value) (int, error) {
	if ai, af, aFloat, ok := number(a); ok {
		if bi, bf, bFloat, ok := number(b); ok {
			if aFloat || bFloat {
				return cmpFloat(af, bf), nil
			}
			switch {
			case ai < bi:
				return -1, nil
			case ai > bi:
				return 1, nil
			}
			return 0, nil
		}
	}
	if x, ok := a.(string); ok {
		if y, ok := b.(string); ok {
			return strings.Compare(x, y), nil
		}
	}
	return 0, typeError("cannot order %T and %T", a, b)
}

func cmpFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Contains implements `needle in haystack`.
func Contains(haystack, needle Value) (bool, error) {
	switch h := haystack.(type) {
	case string:
		n, ok := needle.(string)
		if !ok {
			return false, typeError("'in <string>' requires a string, not %T", needle)
		}
		return strings.Contains(h, n), nil
	case *Dict:
		n, ok := needle.(string)
		if !ok {
			return false, nil
		}
		_, found := h.Get(n)
		return found, nil
	case *List:
		for _, e := range h.Items {
			if Equal(e, needle) {
				return true, nil
			}
		}
		return false, nil
	}
	return false, typeError("'in' not supported on %T", haystack)
}

// GetAttr implements a.name.
func GetAttr(a Value, name string) (Value, error) {
	switch x := a.(type) {
	case *Dict:
		if v, ok := x.Get(name); ok {
			return v, nil
		}
	case *Loop:
		if v, ok := x.Member(name); ok {
			return v, nil
		}
	case UndefinedType:
		return nil, undefinedError("attribute access on the undefined value")
	}
	return Undefined, nil
}

// GetItem implements a[key].
func GetItem(a, key Value) (Value, error) {
	if IsUndefined(a) {
		return nil, undefinedError("subscript of the undefined value")
	}
	if IsUndefined(key) {
		return nil, undefinedError("subscript by the undefined value")
	}
	switch x := a.(type) {
	case *Dict:
		if k, ok := key.(string); ok {
			if v, ok := x.Get(k); ok {
				return v, nil
			}
		}
	case *Loop:
		if k, ok := key.(string); ok {
			if v, ok := x.Member(k); ok {
				return v, nil
			}
		}
	case *List:
		if i, ok := indexKey(key); ok {
			n := int64(len(x.Items))
			if i < 0 {
				i += n
			}
			if i >= 0 && i < n {
				return x.Items[i], nil
			}
		}
	case string:
		if i, ok := indexKey(key); ok {
			if c, ok := stringIndex(x, i); ok {
				return c, nil
			}
		}
	}
	return Undefined, nil
}

func indexKey(key Value) (int64, bool) {
	switch k := key.(type) {
	case int64:
		return k, true
	case bool:
		if k {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func stringIndex(s string, i int64) (string, bool) {
	if i < 0 {
		i += int64(utf8.RuneCountInString(s))
		if i < 0 {
			return "", false
		}
	}
	for pos := 0; pos < len(s); {
		_, w := utf8.DecodeRuneInString(s[pos:])
		if i == 0 {
			return s[pos : pos+w], true
		}
		i--
		pos += w
	}
	return "", false
}

// Op is a binary arithmetic or string operator.
type Op int

// The binary operators.
const (
	OpAdd Op = iota
	OpSub
	OpMul
	OpDiv
	OpFloorDiv
	OpMod
	OpPow
	OpConcat
)

// maxRepeat bounds the size of a repeated string.
const maxRepeat = 1 << 30

// Binary applies a binary operator to two evaluated operands.
func Binary(op Op, a, b Value) (Value, error) {
	if IsUndefined(a) || IsUndefined(b) {
		return nil, undefinedError("operator applied to the undefined value")
	}
	if op == OpConcat {
		sa, err := ToString(a)
		if err != nil {
			return nil, err
		}
		sb, err := ToString(b)
		if err != nil {
			return nil, err
		}
		return sa + sb, nil
	}
	ai, af, aFloat, aNum := number(a)
	bi, bf, bFloat, bNum := number(b)
	if aNum && bNum {
		return numeric(op, ai, af, aFloat, bi, bf, bFloat)
	}
	switch op {
	case OpAdd:
		switch x := a.(type) {
		case string:
			if y, ok := b.(string); ok {
				return x + y, nil
			}
		case *List:
			if y, ok := b.(*List); ok {
				items := make([]Value, 0, len(x.Items)+len(y.Items))
				items = append(items, x.Items...)
				items = append(items, y.Items...)
				return NewList(items), nil
			}
		}
	case OpMul:
		if s, ok := a.(string); ok && bNum && !bFloat {
			return repeat(s, bi)
		}
		if s, ok := b.(string); ok && aNum && !aFloat {
			return repeat(s, ai)
		}
	}
	return nil, typeError("unsupported operand types %T and %T", a, b)
}

func repeat(s string, n int64) (Value, error) {
	if n <= 0 || s == "" {
		return "", nil
	}
	if int64(len(s)) > maxRepeat/n {
		return nil, typeError("string repetition too large")
	}
	return strings.Repeat(s, int(n)), nil
}

func numeric(op Op, ai int64, af float64, aFloat bool, bi int64, bf float64, bFloat bool) (Value, error) {
	bothInt := !aFloat && !bFloat
	switch op {
	case OpAdd:
		if bothInt {
			return ai + bi, nil
		}
		return af + bf, nil
	case OpSub:
		if bothInt {
			return ai - bi, nil
		}
		return af - bf, nil
	case OpMul:
		if bothInt {
			return ai * bi, nil
		}
		return af * bf, nil
	case OpDiv:
		if bf == 0 {
			return nil, typeError("division by zero")
		}
		return af / bf, nil
	case OpFloorDiv:
		if bf == 0 {
			return nil, typeError("division by zero")
		}
		if bothInt {
			q := ai / bi
			if ai%bi != 0 && (ai < 0) != (bi < 0) {
				q--
			}
			return q, nil
		}
		q, _ := floatDivMod(af, bf)
		return q, nil
	case OpMod:
		if bf == 0 {
			return nil, typeError("modulo by zero")
		}
		if bothInt {
			m := ai % bi
			if m != 0 && (m < 0) != (bi < 0) {
				m += bi
			}
			return m, nil
		}
		_, m := floatDivMod(af, bf)
		return m, nil
	case OpPow:
		if bothInt {
			if bi >= 0 {
				return intPow(ai, bi), nil
			}
			if ai == 0 {
				return nil, typeError("zero to a negative power")
			}
			return math.Pow(af, bf), nil
		}
		if af == 0 && bf < 0 {
			return nil, typeError("zero to a negative power")
		}
		return math.Pow(af, bf), nil
	}
	return nil, typeError("unknown operator")
}

func intPow(base, exp int64) int64 {
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

// floatDivMod is floor division and modulo for floats with the semantics of
// Python's divmod (the remainder takes the sign of the divisor).
func floatDivMod(v, w float64) (floordiv, mod float64) {
	mod = math.Mod(v, w)
	div := (v - mod) / w
	if mod != 0 {
		if (w < 0) != (mod < 0) {
			mod += w
			div--
		}
	} else {
		mod = math.Copysign(0, w)
	}
	if div != 0 {
		floordiv = math.Floor(div)
		if div-floordiv > 0.5 {
			floordiv++
		}
	} else {
		floordiv = math.Copysign(0, v/w)
	}
	return floordiv, mod
}

// Neg implements unary minus.
func Neg(v Value) (Value, error) {
	switch x := v.(type) {
	case int64:
		return -x, nil
	case float64:
		return -x, nil
	case bool:
		if x {
			return int64(-1), nil
		}
		return int64(0), nil
	case UndefinedType:
		return nil, undefinedError("negating the undefined value")
	}
	return nil, typeError("cannot negate %T", v)
}
