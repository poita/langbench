package value

import (
	"math"
	"unicode/utf8"
)

// Index implements t[k] for a single index k: a string key on an object, a
// number on an array, or anything on null (except a key of another kind,
// which is always an error).
func Index(t, k Value) (Value, error) {
	switch k.k {
	case KindString:
		switch t.k {
		case KindObject:
			v, _ := t.Obj().Get(k.Str())
			return v, nil
		case KindNull:
			return Null, nil
		}
		return Null, &Error{Msg: "cannot index " + t.TypeName() + " with string"}
	case KindNumber:
		switch t.k {
		case KindArray:
			return IndexArray(t, k.Float()), nil
		case KindNull:
			return Null, nil
		}
		return Null, &Error{Msg: "cannot index " + t.TypeName() + " with number"}
	}
	return Null, &Error{Msg: "cannot index " + t.TypeName() + " with " + k.TypeName()}
}

// IndexArray returns element i of array a (negative i counts from the end,
// non-integers are truncated toward zero); null if out of range.
func IndexArray(a Value, i float64) Value {
	es := a.Elems()
	if i != i {
		return Null
	}
	n := int(math.Trunc(math.Max(math.Min(i, 1<<40), -(1 << 40))))
	if n < 0 {
		n += len(es)
	}
	if n < 0 || n >= len(es) {
		return Null
	}
	return es[n]
}

// Iterate calls fn for each element of an array or each value of an object
// (in insertion order). It returns an error for any other kind of value, or
// the first error returned by fn.
func Iterate(t Value, fn func(Value) error) error {
	switch t.k {
	case KindArray:
		for _, e := range t.Elems() {
			if err := fn(e); err != nil {
				return err
			}
		}
		return nil
	case KindObject:
		for _, e := range t.Obj().entries {
			if err := fn(e.Val); err != nil {
				return err
			}
		}
		return nil
	}
	return &Error{Msg: "cannot iterate over " + t.TypeName()}
}

// Iterable reports whether t is an array or an object.
func Iterable(t Value) bool { return t.k == KindArray || t.k == KindObject }

// Slice implements t[from:to]. A null from or to means "not given". Arrays
// are sliced by element and strings by code point; null slices to null.
func Slice(t, from, to Value) (Value, error) {
	if t.k != KindArray && t.k != KindString {
		if t.k == KindNull {
			return Null, nil
		}
		return Null, &Error{Msg: "cannot slice " + t.TypeName()}
	}
	if (from.k != KindNumber && from.k != KindNull) || (to.k != KindNumber && to.k != KindNull) {
		return Null, &Error{Msg: "start and end indices of an array slice must be numbers"}
	}
	if t.k == KindArray {
		es := t.Elems()
		lo, hi := sliceBounds(len(es), from, to)
		if lo == 0 && hi == len(es) {
			return t, nil
		}
		out := make([]Value, hi-lo)
		copy(out, es[lo:hi])
		return Array(out), nil
	}
	s := t.Str()
	n := utf8.RuneCountInString(s)
	lo, hi := sliceBounds(n, from, to)
	if n == len(s) {
		return String(s[lo:hi]), nil
	}
	// Convert code point offsets to byte offsets.
	bl, bh := len(s), len(s)
	cp := 0
	for i := range s {
		if cp == lo {
			bl = i
		}
		if cp == hi {
			bh = i
			break
		}
		cp++
	}
	if lo == n {
		bl = len(s)
	}
	return String(s[bl:bh]), nil
}

func sliceBounds(n int, from, to Value) (int, int) {
	lo, hi := 0, n
	if from.k == KindNumber {
		lo = clampIndex(math.Floor(from.Float()), n)
	}
	if to.k == KindNumber {
		hi = clampIndex(math.Ceil(to.Float()), n)
	}
	if hi < lo {
		hi = lo
	}
	return lo, hi
}

func clampIndex(f float64, n int) int {
	if f != f {
		return 0
	}
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
