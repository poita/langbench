package jq

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

// Error is a runtime error raised while evaluating a filter (type errors,
// division by zero, the error builtin, ...). Value is the error payload.
type Error struct {
	Value Value
}

func (e *Error) Error() string {
	if s, ok := e.Value.(string); ok {
		return s
	}
	return string(Marshal(e.Value)) + " (not a string)"
}

func errorf(format string, args ...any) error {
	return &Error{Value: fmt.Sprintf(format, args...)}
}

// indexValue implements t[k] for a single target and key.
func indexValue(t, k Value) (Value, error) {
	switch key := k.(type) {
	case string:
		switch x := t.(type) {
		case *Object:
			v, _ := x.Get(key)
			return v, nil
		case nil:
			return nil, nil
		}
		return nil, errorf("cannot index %s with string %q", TypeName(t), key)
	case float64:
		switch x := t.(type) {
		case []Value:
			i := truncInt(key)
			if i < 0 {
				i += len(x)
			}
			if i < 0 || i >= len(x) {
				return nil, nil
			}
			return x[i], nil
		case nil:
			return nil, nil
		}
		return nil, errorf("cannot index %s with number", TypeName(t))
	}
	return nil, errorf("cannot index %s with %s", TypeName(t), TypeName(k))
}

// truncInt converts f to an int, truncating toward zero and saturating.
func truncInt(f float64) int {
	switch {
	case f != f:
		return 0
	case f >= math.MaxInt32*1024:
		return math.MaxInt32 * 1024
	case f <= -math.MaxInt32*1024:
		return -math.MaxInt32 * 1024
	}
	return int(f)
}

// sliceBounds resolves optional slice bounds (nil = default) against length n.
func sliceBounds(n int, from, to Value) (int, int, error) {
	lo, hi := 0, n
	if from != nil {
		f, ok := from.(float64)
		if !ok {
			return 0, 0, errorf("slice start must be a number")
		}
		lo = truncInt(f)
	}
	if to != nil {
		f, ok := to.(float64)
		if !ok {
			return 0, 0, errorf("slice end must be a number")
		}
		hi = truncInt(f)
	}
	if lo < 0 {
		lo += n
	}
	if hi < 0 {
		hi += n
	}
	lo = max(0, min(lo, n))
	hi = max(0, min(hi, n))
	if hi < lo {
		hi = lo
	}
	return lo, hi, nil
}

func sliceValue(t, from, to Value) (Value, error) {
	switch x := t.(type) {
	case nil:
		return nil, nil
	case []Value:
		lo, hi, err := sliceBounds(len(x), from, to)
		if err != nil {
			return nil, err
		}
		return x[lo:hi:hi], nil
	case string:
		if utf8.RuneCountInString(x) == len(x) { // ASCII fast path
			lo, hi, err := sliceBounds(len(x), from, to)
			if err != nil {
				return nil, err
			}
			return x[lo:hi], nil
		}
		r := []rune(x)
		lo, hi, err := sliceBounds(len(r), from, to)
		if err != nil {
			return nil, err
		}
		return string(r[lo:hi]), nil
	}
	return nil, errorf("cannot slice %s", TypeName(t))
}

// ---- arithmetic ----

func opAdd(a, b Value) (Value, error) {
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
			r := make([]Value, len(x)+len(y))
			copy(r, x)
			copy(r[len(x):], y)
			return r, nil
		}
	case *Object:
		if y, ok := b.(*Object); ok {
			return mergeObjects(x, y), nil
		}
	}
	return nil, errorf("%s and %s cannot be added", TypeName(a), TypeName(b))
}

// mergeObjects returns a with every key of b set in order.
func mergeObjects(a, b *Object) *Object {
	if b.Len() == 0 {
		return a
	}
	if r, ok := a.extend(b); ok {
		return r
	}
	r := a.Copy(b.Len())
	for i, k := range b.keys {
		r.Set(k, b.vals[i])
	}
	return r
}

func opSub(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		if y, ok := b.(float64); ok {
			return x - y, nil
		}
	case []Value:
		if y, ok := b.([]Value); ok {
			r := make([]Value, 0, len(x))
		outer:
			for _, e := range x {
				for _, f := range y {
					if Equal(e, f) {
						continue outer
					}
				}
				r = append(r, e)
			}
			return r, nil
		}
	}
	return nil, errorf("%s and %s cannot be subtracted", TypeName(a), TypeName(b))
}

func opMul(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		switch y := b.(type) {
		case float64:
			return x * y, nil
		case string:
			return repeatString(y, x)
		}
	case string:
		if y, ok := b.(float64); ok {
			return repeatString(x, y)
		}
	case *Object:
		if y, ok := b.(*Object); ok {
			return deepMerge(x, y), nil
		}
	}
	return nil, errorf("%s and %s cannot be multiplied", TypeName(a), TypeName(b))
}

func repeatString(s string, n float64) (Value, error) {
	if n < 0 {
		return nil, nil
	}
	cnt := truncInt(n)
	if cnt == 0 {
		return "", nil
	}
	if len(s)*cnt > 1<<30 {
		return nil, errorf("repeat string result too long")
	}
	return strings.Repeat(s, cnt), nil
}

func deepMerge(a, b *Object) *Object {
	r := a.Copy(b.Len())
	for i, k := range b.keys {
		bv := b.vals[i]
		if av, ok := r.Get(k); ok {
			if ao, ok := av.(*Object); ok {
				if bo, ok := bv.(*Object); ok {
					r.Set(k, deepMerge(ao, bo))
					continue
				}
			}
		}
		r.Set(k, bv)
	}
	return r
}

func opDiv(a, b Value) (Value, error) {
	switch x := a.(type) {
	case float64:
		if y, ok := b.(float64); ok {
			if y == 0 {
				return nil, errorf("%v and %v cannot be divided because the divisor is zero", x, y)
			}
			return x / y, nil
		}
	case string:
		if y, ok := b.(string); ok {
			return splitString(x, y), nil
		}
	}
	return nil, errorf("%s and %s cannot be divided", TypeName(a), TypeName(b))
}

func splitString(s, sep string) Value {
	res := []Value{}
	if s == "" {
		return res
	}
	if sep == "" {
		for _, r := range s {
			res = append(res, string(r))
		}
		return res
	}
	for _, p := range strings.Split(s, sep) {
		res = append(res, p)
	}
	return res
}

func opMod(a, b Value) (Value, error) {
	x, ok1 := a.(float64)
	y, ok2 := b.(float64)
	if !ok1 || !ok2 {
		return nil, errorf("%s and %s cannot be divided", TypeName(a), TypeName(b))
	}
	xi, yi := truncInt64(x), truncInt64(y)
	if yi == 0 {
		return nil, errorf("cannot be divided because the divisor is zero")
	}
	if yi == -1 {
		return 0.0, nil
	}
	return float64(xi % yi), nil
}

func truncInt64(f float64) int64 {
	switch {
	case f != f:
		return 0
	case f >= 9.2e18:
		return math.MaxInt64
	case f <= -9.2e18:
		return math.MinInt64
	}
	return int64(f)
}

func cmpFn(test func(c int) bool) func(a, b Value) (Value, error) {
	return func(a, b Value) (Value, error) { return test(Compare(a, b)), nil }
}

var binaryOps = map[string]func(a, b Value) (Value, error){
	"+":  opAdd,
	"-":  opSub,
	"*":  opMul,
	"/":  opDiv,
	"%":  opMod,
	"==": cmpFn(func(c int) bool { return c == 0 }),
	"!=": cmpFn(func(c int) bool { return c != 0 }),
	"<":  cmpFn(func(c int) bool { return c < 0 }),
	"<=": cmpFn(func(c int) bool { return c <= 0 }),
	">":  cmpFn(func(c int) bool { return c > 0 }),
	">=": cmpFn(func(c int) bool { return c >= 0 }),
}
