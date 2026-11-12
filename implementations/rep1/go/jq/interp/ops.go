package interp

import (
	"math"
	"strings"
	"unicode/utf8"

	"example.com/jq/value"
)

type Value = value.Value

// toIndex converts a numeric index to an int, truncating toward zero; ok is
// false when the number is outside any possible array range.
func toIndex(f float64) (int, bool) {
	if math.IsNaN(f) || math.Abs(f) > 1<<53 {
		return 0, false
	}
	return int(f), true
}

// index implements t[k].
func index(t, k Value) (Value, error) {
	switch tv := t.(type) {
	case *value.Object:
		if ks, ok := k.(string); ok {
			v, _ := tv.Get(ks)
			return v, nil
		}
	case []Value:
		if kf, ok := k.(float64); ok {
			i, ok := toIndex(kf)
			if !ok {
				return nil, nil
			}
			if i < 0 {
				i += len(tv)
			}
			if i < 0 || i >= len(tv) {
				return nil, nil
			}
			return tv[i], nil
		}
	case nil:
		switch k.(type) {
		case string, float64:
			return nil, nil
		}
	}
	if ks, ok := k.(string); ok {
		return nil, errf("Cannot index %s with \"%s\"", value.TypeName(t), ks)
	}
	return nil, errf("Cannot index %s with %s", value.TypeName(t), value.TypeName(k))
}

// iterate calls f on each element of an array or value of an object.
func iterate(t Value, f func(Value) error) error {
	switch tv := t.(type) {
	case []Value:
		for _, e := range tv {
			if err := f(e); err != nil {
				return err
			}
		}
		return nil
	case *value.Object:
		for _, e := range tv.Values() {
			if err := f(e); err != nil {
				return err
			}
		}
		return nil
	}
	return errf("Cannot iterate over %s", describe(t))
}

func sliceBound(b Value, def, length int, ceil bool) (int, error) {
	switch x := b.(type) {
	case nil:
		return def, nil
	case float64:
		if math.IsNaN(x) {
			return def, nil
		}
		if x < 0 {
			x += float64(length)
		}
		if ceil {
			x = math.Ceil(x)
		} else {
			x = math.Floor(x)
		}
		if x < 0 {
			return 0, nil
		}
		if x > float64(length) {
			return length, nil
		}
		return int(x), nil
	}
	return 0, errf("Start and end indices of an array slice must be numbers")
}

// slice implements t[from:to]; nil bounds mean "absent".
func slice(t, from, to Value) (Value, error) {
	switch tv := t.(type) {
	case nil:
		return nil, nil
	case []Value:
		a, b, err := sliceRange(from, to, len(tv))
		if err != nil {
			return nil, err
		}
		return tv[a:b:b], nil
	case string:
		n := len(tv)
		runes := utf8.RuneCountInString(tv)
		a, b, err := sliceRange(from, to, runes)
		if err != nil {
			return nil, err
		}
		if runes == n {
			return tv[a:b], nil
		}
		return tv[runeOffset(tv, a):runeOffset(tv, b)], nil
	}
	return nil, errf("Cannot index %s with object", value.TypeName(t))
}

func sliceRange(from, to Value, length int) (int, int, error) {
	a, err := sliceBound(from, 0, length, false)
	if err != nil {
		return 0, 0, err
	}
	b, err := sliceBound(to, length, length, true)
	if err != nil {
		return 0, 0, err
	}
	if b < a {
		b = a
	}
	return a, b, nil
}

// runeOffset returns the byte offset of the n'th code point of s.
func runeOffset(s string, n int) int {
	off := 0
	for ; n > 0 && off < len(s); n-- {
		_, w := utf8.DecodeRuneInString(s[off:])
		off += w
	}
	return off
}

// binary dispatches an operator on two values.
func binary(op string, a, b Value) (Value, error) {
	switch op {
	case "+":
		return add(a, b)
	case "-":
		return sub(a, b)
	case "*":
		return mul(a, b)
	case "/":
		return div(a, b)
	case "%":
		return mod(a, b)
	case "==":
		return value.Compare(a, b) == 0, nil
	case "!=":
		return value.Compare(a, b) != 0, nil
	case "<":
		return value.Compare(a, b) < 0, nil
	case "<=":
		return value.Compare(a, b) <= 0, nil
	case ">":
		return value.Compare(a, b) > 0, nil
	case ">=":
		return value.Compare(a, b) >= 0, nil
	}
	panic("interp: unknown operator " + op)
}

func add(a, b Value) (Value, error) {
	if a == nil {
		return b, nil
	}
	if b == nil {
		return a, nil
	}
	switch x := a.(type) {
	case float64:
		if y, ok := b.(float64); ok {
			return x + y, nil
		}
	case string:
		if y, ok := b.(string); ok {
			return x + y, nil
		}
	case []Value:
		if y, ok := b.([]Value); ok {
			if len(y) == 0 {
				return x, nil
			}
			if len(x) == 0 {
				return y, nil
			}
			out := make([]Value, len(x)+len(y))
			copy(out, x)
			copy(out[len(x):], y)
			return out, nil
		}
	case *value.Object:
		if y, ok := b.(*value.Object); ok {
			return value.Merge(x, y), nil
		}
	}
	return nil, errf("%s and %s cannot be added", describe(a), describe(b))
}

func sub(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		if y, ok := b.(float64); ok {
			return x - y, nil
		}
	case []Value:
		if y, ok := b.([]Value); ok {
			out := make([]Value, 0, len(x))
		next:
			for _, e := range x {
				for _, r := range y {
					if value.Equal(e, r) {
						continue next
					}
				}
				out = append(out, e)
			}
			return out, nil
		}
	}
	return nil, errf("%s and %s cannot be subtracted", describe(a), describe(b))
}

func mul(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		switch y := b.(type) {
		case float64:
			return x * y, nil
		case string:
			return repeat(y, x)
		}
	case string:
		if y, ok := b.(float64); ok {
			return repeat(x, y)
		}
	case *value.Object:
		if y, ok := b.(*value.Object); ok {
			return value.DeepMerge(x, y), nil
		}
	}
	return nil, errf("%s and %s cannot be multiplied", describe(a), describe(b))
}

func repeat(s string, n float64) (Value, error) {
	if n < 0 || math.IsNaN(n) {
		return nil, nil
	}
	n = math.Trunc(n)
	if s == "" || n == 0 {
		return "", nil
	}
	if n*float64(len(s)) > 1<<30 {
		return nil, errf("Repeat string result too long")
	}
	return strings.Repeat(s, int(n)), nil
}

func div(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		if y, ok := b.(float64); ok {
			if y == 0 {
				return nil, errf("%s and %s cannot be divided because the divisor is zero", describe(a), describe(b))
			}
			return x / y, nil
		}
	case string:
		if y, ok := b.(string); ok {
			return split(x, y), nil
		}
	}
	return nil, errf("%s and %s cannot be divided", describe(a), describe(b))
}

// split splits s on sep; an empty s gives [] and an empty sep splits into
// code points.
func split(s, sep string) []Value {
	if s == "" {
		return []Value{}
	}
	if sep == "" {
		out := make([]Value, 0, len(s))
		for i := 0; i < len(s); {
			_, w := utf8.DecodeRuneInString(s[i:])
			out = append(out, s[i:i+w])
			i += w
		}
		return out
	}
	out := make([]Value, 0, strings.Count(s, sep)+1)
	for {
		i := strings.Index(s, sep)
		if i < 0 {
			return append(out, s)
		}
		out = append(out, s[:i])
		s = s[i+len(sep):]
	}
}

func mod(a, b Value) (Value, error) {
	x, ok1 := a.(float64)
	y, ok2 := b.(float64)
	if !ok1 || !ok2 {
		return nil, errf("%s and %s cannot be divided", describe(a), describe(b))
	}
	xi, yi := clampInt(x), clampInt(y)
	if yi == 0 {
		return nil, errf("%s and %s cannot be divided because the divisor is zero", describe(a), describe(b))
	}
	if yi == -1 {
		return 0.0, nil
	}
	return float64(xi % yi), nil
}

func clampInt(f float64) int64 {
	switch {
	case math.IsNaN(f):
		return 0
	case f >= math.MaxInt64:
		return math.MaxInt64
	case f <= math.MinInt64:
		return math.MinInt64
	}
	return int64(f)
}
