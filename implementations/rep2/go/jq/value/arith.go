package value

import (
	"math"
	"strings"
)

func typeErr(what string, a, b Value) *Error {
	return &Error{Msg: a.TypeName() + " and " + b.TypeName() + " cannot be " + what}
}

// Add implements the + operator.
func Add(a, b Value) (Value, error) {
	if a.k == KindNull {
		return b, nil
	}
	if b.k == KindNull {
		return a, nil
	}
	if a.k != b.k && !(a.k <= KindTrue && b.k <= KindTrue) {
		return Null, typeErr("added", a, b)
	}
	switch a.k {
	case KindNumber:
		return Number(a.Float() + b.Float()), nil
	case KindString:
		return String(a.Str() + b.Str()), nil
	case KindArray:
		ea, eb := a.Elems(), b.Elems()
		if len(eb) == 0 {
			return a, nil
		}
		out := make([]Value, len(ea)+len(eb))
		copy(out, ea)
		copy(out[len(ea):], eb)
		return Array(out), nil
	case KindObject:
		return ObjectValue(MergeObjects(a.Obj(), b.Obj())), nil
	}
	return Null, typeErr("added", a, b)
}

// MergeObjects returns a new object: a with every key of b set in order
// (existing keys keep their position, new keys are appended).
func MergeObjects(a, b *Object) *Object {
	out := a.Clone(len(b.entries))
	for _, e := range b.entries {
		out.Set(e.Key, e.Val)
	}
	return out
}

// DeepMerge implements object * object: like MergeObjects, but when both
// values under a key are objects they are merged recursively.
func DeepMerge(a, b *Object) *Object {
	out := a.Clone(len(b.entries))
	for _, e := range b.entries {
		if e.Val.k == KindObject {
			if i := out.find(e.Key); i >= 0 && out.entries[i].Val.k == KindObject {
				out.Set(e.Key, ObjectValue(DeepMerge(out.entries[i].Val.Obj(), e.Val.Obj())))
				continue
			}
		}
		out.Set(e.Key, e.Val)
	}
	return out
}

// Sub implements the - operator.
func Sub(a, b Value) (Value, error) {
	switch {
	case a.k == KindNumber && b.k == KindNumber:
		return Number(a.Float() - b.Float()), nil
	case a.k == KindArray && b.k == KindArray:
		ea, eb := a.Elems(), b.Elems()
		out := make([]Value, 0, len(ea))
	next:
		for _, x := range ea {
			for _, y := range eb {
				if Compare(x, y) == 0 {
					continue next
				}
			}
			out = append(out, x)
		}
		return Array(out), nil
	}
	return Null, typeErr("subtracted", a, b)
}

// Mul implements the * operator.
func Mul(a, b Value) (Value, error) {
	switch {
	case a.k == KindNumber && b.k == KindNumber:
		return Number(a.Float() * b.Float()), nil
	case a.k == KindString && b.k == KindNumber:
		return repeat(a.Str(), b.Float()), nil
	case a.k == KindNumber && b.k == KindString:
		return repeat(b.Str(), a.Float()), nil
	case a.k == KindObject && b.k == KindObject:
		return ObjectValue(DeepMerge(a.Obj(), b.Obj())), nil
	}
	return Null, typeErr("multiplied", a, b)
}

func repeat(s string, n float64) Value {
	if n < 0 || n != n {
		return Null
	}
	if n > 1<<31 {
		n = 1 << 31
	}
	return String(strings.Repeat(s, int(n)))
}

// Div implements the / operator.
func Div(a, b Value) (Value, error) {
	switch {
	case a.k == KindNumber && b.k == KindNumber:
		if b.Float() == 0 {
			return Null, &Error{Msg: "number and number cannot be divided because the divisor is zero"}
		}
		return Number(a.Float() / b.Float()), nil
	case a.k == KindString && b.k == KindString:
		return split(a.Str(), b.Str()), nil
	}
	return Null, typeErr("divided", a, b)
}

func split(s, sep string) Value {
	if s == "" {
		return Array([]Value{})
	}
	parts := strings.Split(s, sep)
	out := make([]Value, len(parts))
	for i, p := range parts {
		out[i] = String(p)
	}
	return Array(out)
}

// Mod implements the % operator: both operands are truncated toward zero and
// the result has the sign of the dividend.
func Mod(a, b Value) (Value, error) {
	if a.k != KindNumber || b.k != KindNumber {
		return Null, typeErr("divided", a, b)
	}
	x, y := toInt(a.Float()), toInt(b.Float())
	if y == 0 {
		return Null, &Error{Msg: "number and number cannot be divided because the divisor is zero"}
	}
	if y == -1 {
		return Number(0), nil
	}
	return Number(float64(x % y)), nil
}

func toInt(f float64) int64 {
	switch {
	case f != f:
		return 0
	case f >= math.MaxInt64:
		return math.MaxInt64
	case f <= math.MinInt64:
		return math.MinInt64
	}
	return int64(f)
}

// Neg implements unary minus.
func Neg(a Value) (Value, error) {
	if a.k != KindNumber {
		return Null, &Error{Msg: a.TypeName() + " cannot be negated"}
	}
	return Number(-a.Float()), nil
}
