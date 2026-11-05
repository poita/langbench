package jq

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"jq/value"
)

// Error is a runtime error raised by a filter (for example by indexing a
// number or by calling error). It carries the value jq would use as the
// error message.
type Error struct {
	Value value.Value
}

func (e *Error) Error() string {
	if e.Value.IsString() {
		return e.Value.Str()
	}
	return value.JSON(e.Value) + " (not a string)"
}

func errorf(format string, args ...any) error {
	return &Error{Value: value.String(fmt.Sprintf(format, args...))}
}

// short renders v for an error message, truncated.
func short(v value.Value) string {
	s := value.JSON(v)
	if len(s) > 11 {
		s = s[:10] + "..."
	}
	return s
}

// indexField implements .name; ok is false when the operation is an error.
func indexField(t value.Value, name string) (value.Value, bool) {
	switch t.Kind() {
	case value.KindObject:
		v, _ := t.Obj().Get(name)
		return v, true
	case value.KindNull:
		return value.Null, true
	}
	return value.Null, false
}

func fieldError(t value.Value, name string) error {
	return errorf("Cannot index %s with \"%s\"", t.TypeName(), name)
}

// indexValue implements t[k].
func indexValue(t, k value.Value) (value.Value, bool) {
	switch k.Kind() {
	case value.KindString:
		return indexField(t, k.Str())
	case value.KindNumber:
		switch t.Kind() {
		case value.KindNull:
			return value.Null, true
		case value.KindArray:
			items := t.Items()
			f := math.Trunc(k.Float())
			if f < 0 {
				f += float64(len(items))
			}
			if f < 0 || f >= float64(len(items)) {
				return value.Null, true
			}
			return items[int(f)], true
		}
	}
	return value.Null, false
}

func indexError(t, k value.Value) error {
	if k.IsString() {
		return fieldError(t, k.Str())
	}
	return errorf("Cannot index %s with %s", t.TypeName(), k.TypeName())
}

// iterate calls f for each element of an array or value of an object.
func iterate(t value.Value, f func(value.Value) error) (bool, error) {
	switch t.Kind() {
	case value.KindArray:
		for _, e := range t.Items() {
			if err := f(e); err != nil {
				return true, err
			}
		}
		return true, nil
	case value.KindObject:
		o := t.Obj()
		for i, n := 0, o.Len(); i < n; i++ {
			if err := f(o.ValueAt(i)); err != nil {
				return true, err
			}
		}
		return true, nil
	}
	return false, nil
}

// sliceValue implements t[from:to]; from and to may be null for "omitted".
func sliceValue(t, from, to value.Value) (value.Value, bool) {
	if t.IsNull() {
		if (from.IsNull() || from.IsNumber()) && (to.IsNull() || to.IsNumber()) {
			return value.Null, true
		}
		return value.Null, false
	}
	if !(from.IsNull() || from.IsNumber()) || !(to.IsNull() || to.IsNumber()) {
		return value.Null, false
	}
	switch t.Kind() {
	case value.KindArray:
		items := t.Items()
		lo, hi := sliceBounds(len(items), from, to)
		return value.Array(append([]value.Value(nil), items[lo:hi]...)), true
	case value.KindString:
		s := t.Str()
		n := utf8.RuneCountInString(s)
		lo, hi := sliceBounds(n, from, to)
		if n == len(s) {
			return value.String(s[lo:hi]), true
		}
		bl := runeOffset(s, lo)
		bh := bl + runeOffset(s[bl:], hi-lo)
		return value.String(s[bl:bh]), true
	}
	return value.Null, false
}

func sliceBounds(n int, from, to value.Value) (int, int) {
	lo, hi := 0, n
	if from.IsNumber() {
		lo = clampIndex(math.Floor(from.Float()), n)
	}
	if to.IsNumber() {
		hi = clampIndex(math.Ceil(to.Float()), n)
	}
	if hi < lo {
		hi = lo
	}
	return lo, hi
}

func clampIndex(f float64, n int) int {
	if f < 0 {
		f += float64(n)
	}
	if f < 0 {
		return 0
	}
	if f > float64(n) {
		return n
	}
	return int(f)
}

func sliceError(t value.Value) error {
	return errorf("Cannot index %s with object", t.TypeName())
}

// binaryOp evaluates a op b.
func binaryOp(op binOp, a, b value.Value) (value.Value, error) {
	switch op {
	case opEq:
		return value.Bool(value.Compare(a, b) == 0), nil
	case opNe:
		return value.Bool(value.Compare(a, b) != 0), nil
	case opLt:
		return value.Bool(value.Compare(a, b) < 0), nil
	case opLe:
		return value.Bool(value.Compare(a, b) <= 0), nil
	case opGt:
		return value.Bool(value.Compare(a, b) > 0), nil
	case opGe:
		return value.Bool(value.Compare(a, b) >= 0), nil
	case opAdd:
		return addValues(a, b)
	case opSub:
		if a.IsNumber() && b.IsNumber() {
			return value.Number(a.Float() - b.Float()), nil
		}
		if a.IsArray() && b.IsArray() {
			var out []value.Value
			ys := b.Items()
			for _, x := range a.Items() {
				keep := true
				for _, y := range ys {
					if value.Compare(x, y) == 0 {
						keep = false
						break
					}
				}
				if keep {
					out = append(out, x)
				}
			}
			if out == nil {
				out = []value.Value{}
			}
			return value.Array(out), nil
		}
	case opMul:
		switch {
		case a.IsNumber() && b.IsNumber():
			return value.Number(a.Float() * b.Float()), nil
		case a.IsString() && b.IsNumber():
			return repeatString(a.Str(), b.Float()), nil
		case a.IsNumber() && b.IsString():
			return repeatString(b.Str(), a.Float()), nil
		case a.IsObject() && b.IsObject():
			return value.ObjectValue(value.DeepMerge(a.Obj(), b.Obj())), nil
		}
	case opDiv:
		if a.IsNumber() && b.IsNumber() {
			if b.Float() == 0 {
				return value.Null, errorf("%s and %s cannot be divided because the divisor is zero", short(a), short(b))
			}
			return value.Number(a.Float() / b.Float()), nil
		}
		if a.IsString() && b.IsString() {
			return splitString(a.Str(), b.Str()), nil
		}
	case opMod:
		if a.IsNumber() && b.IsNumber() {
			x, y := truncInt(a.Float()), truncInt(b.Float())
			if y == 0 {
				return value.Null, errorf("%s and %s cannot be divided because the divisor is zero", short(a), short(b))
			}
			return value.Number(float64(x % y)), nil
		}
	}
	return value.Null, errorf("%s (%s) and %s (%s) cannot be %s", a.TypeName(), short(a), b.TypeName(), short(b), opVerb(op))
}

func opVerb(op binOp) string {
	switch op {
	case opAdd:
		return "added"
	case opSub:
		return "subtracted"
	case opMul:
		return "multiplied"
	case opDiv:
		return "divided"
	}
	return "divided"
}

func truncInt(f float64) int64 {
	switch {
	case f >= math.MaxInt64:
		return math.MaxInt64
	case f <= math.MinInt64:
		return math.MinInt64
	}
	return int64(f)
}

func addValues(a, b value.Value) (value.Value, error) {
	if a.IsNull() {
		return b, nil
	}
	if b.IsNull() {
		return a, nil
	}
	switch {
	case a.IsNumber() && b.IsNumber():
		return value.Number(a.Float() + b.Float()), nil
	case a.IsString() && b.IsString():
		return value.String(a.Str() + b.Str()), nil
	case a.IsArray() && b.IsArray():
		x, y := a.Items(), b.Items()
		out := make([]value.Value, len(x)+len(y))
		copy(out, x)
		copy(out[len(x):], y)
		return value.Array(out), nil
	case a.IsObject() && b.IsObject():
		return value.ObjectValue(value.Merge(a.Obj(), b.Obj())), nil
	}
	return value.Null, errorf("%s (%s) and %s (%s) cannot be added", a.TypeName(), short(a), b.TypeName(), short(b))
}

func repeatString(s string, n float64) value.Value {
	if n < 0 {
		return value.Null
	}
	return value.String(strings.Repeat(s, int(math.Min(math.Trunc(n), 1<<31))))
}

func splitString(s, sep string) value.Value {
	if s == "" {
		return value.Array([]value.Value{})
	}
	parts := strings.Split(s, sep)
	out := make([]value.Value, len(parts))
	for i, p := range parts {
		out[i] = value.String(p)
	}
	return value.Array(out)
}

// runeOffset returns the byte offset of the n-th code point of s (len(s) if
// s has fewer).
func runeOffset(s string, n int) int {
	for i := range s {
		if n == 0 {
			return i
		}
		n--
	}
	return len(s)
}
