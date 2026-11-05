package interp

import (
	"math"
	"strings"

	"github.com/peter/jq/syntax"
	"github.com/peter/jq/value"
)

// binary applies an arithmetic or comparison operator.
func binary(op syntax.BinOp, l, r value.Value) (value.Value, error) {
	switch op {
	case syntax.Add:
		return add(l, r)
	case syntax.Sub:
		return sub(l, r)
	case syntax.Mul:
		return mul(l, r)
	case syntax.Div:
		return div(l, r)
	case syntax.Mod:
		return mod(l, r)
	}
	c := value.Compare(l, r)
	switch op {
	case syntax.Eq:
		return value.Bool(c == 0), nil
	case syntax.Ne:
		return value.Bool(c != 0), nil
	case syntax.Lt:
		return value.Bool(c < 0), nil
	case syntax.Le:
		return value.Bool(c <= 0), nil
	case syntax.Gt:
		return value.Bool(c > 0), nil
	default:
		return value.Bool(c >= 0), nil
	}
}

func opError(l, r value.Value, verb string) error {
	return errorf("%s and %s cannot be %s", describe(l), describe(r), verb)
}

func add(l, r value.Value) (value.Value, error) {
	if l.IsNull() {
		return r, nil
	}
	if r.IsNull() {
		return l, nil
	}
	if l.Kind() != r.Kind() {
		return value.Null, opError(l, r, "added")
	}
	switch l.Kind() {
	case value.KindNumber:
		return value.Number(l.Float() + r.Float()), nil
	case value.KindString:
		return value.String(l.Str() + r.Str()), nil
	case value.KindArray:
		a, b := l.Elems(), r.Elems()
		out := make([]value.Value, len(a)+len(b))
		copy(out, a)
		copy(out[len(a):], b)
		return value.Array(out), nil
	case value.KindObject:
		return mergeShallow(l.Object(), r.Object()), nil
	}
	return value.Null, opError(l, r, "added")
}

func mergeShallow(a, b *value.Object) value.Value {
	bld := a.Builder(b.Len())
	for _, en := range b.Entries() {
		bld.Set(en.Key, en.Value)
	}
	return bld.Build()
}

func mergeDeep(a, b *value.Object) value.Value {
	bld := a.Builder(b.Len())
	for _, en := range b.Entries() {
		if old, ok := bld.Get(en.Key); ok &&
			old.Kind() == value.KindObject && en.Value.Kind() == value.KindObject {
			bld.Set(en.Key, mergeDeep(old.Object(), en.Value.Object()))
		} else {
			bld.Set(en.Key, en.Value)
		}
	}
	return bld.Build()
}

func sub(l, r value.Value) (value.Value, error) {
	switch {
	case l.Kind() == value.KindNumber && r.Kind() == value.KindNumber:
		return value.Number(l.Float() - r.Float()), nil
	case l.Kind() == value.KindArray && r.Kind() == value.KindArray:
		rs := r.Elems()
		out := []value.Value{}
		for _, x := range l.Elems() {
			keep := true
			for _, y := range rs {
				if value.Equal(x, y) {
					keep = false
					break
				}
			}
			if keep {
				out = append(out, x)
			}
		}
		return value.Array(out), nil
	}
	return value.Null, opError(l, r, "subtracted")
}

func mul(l, r value.Value) (value.Value, error) {
	switch {
	case l.Kind() == value.KindNumber && r.Kind() == value.KindNumber:
		return value.Number(l.Float() * r.Float()), nil
	case l.Kind() == value.KindString && r.Kind() == value.KindNumber:
		return repeat(l.Str(), r.Float()), nil
	case l.Kind() == value.KindNumber && r.Kind() == value.KindString:
		return repeat(r.Str(), l.Float()), nil
	case l.Kind() == value.KindObject && r.Kind() == value.KindObject:
		return mergeDeep(l.Object(), r.Object()), nil
	}
	return value.Null, opError(l, r, "multiplied")
}

func repeat(s string, n float64) value.Value {
	if n < 0 {
		return value.Null
	}
	return value.String(strings.Repeat(s, int(n)))
}

func div(l, r value.Value) (value.Value, error) {
	switch {
	case l.Kind() == value.KindNumber && r.Kind() == value.KindNumber:
		if r.Float() == 0 {
			return value.Null, opError(l, r, "divided because the divisor is zero")
		}
		return value.Number(l.Float() / r.Float()), nil
	case l.Kind() == value.KindString && r.Kind() == value.KindString:
		s, sep := l.Str(), r.Str()
		if s == "" {
			return value.Array([]value.Value{}), nil
		}
		parts := strings.Split(s, sep)
		out := make([]value.Value, len(parts))
		for i, p := range parts {
			out[i] = value.String(p)
		}
		return value.Array(out), nil
	}
	return value.Null, opError(l, r, "divided")
}

func mod(l, r value.Value) (value.Value, error) {
	if l.Kind() != value.KindNumber || r.Kind() != value.KindNumber {
		return value.Null, opError(l, r, "divided")
	}
	a, b := math.Trunc(l.Float()), math.Trunc(r.Float())
	if b == 0 {
		return value.Null, opError(l, r, "divided because the divisor is zero")
	}
	if math.Abs(a) < 1<<62 && math.Abs(b) < 1<<62 {
		return value.Number(float64(int64(a) % int64(b))), nil
	}
	return value.Number(math.Mod(a, b)), nil
}
