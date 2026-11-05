package interp

import (
	"math"
	"unicode/utf8"

	"github.com/peter/jq/value"
)

// evalIndex implements T[K]: for each key k, for each target t, t[k]. With a
// tolerant "?" an indexing failure skips that combination.
func evalIndex(n *node, v value.Value, e *env, out sink) error {
	step := func(t, k value.Value) error {
		r, err := index(t, k)
		if err != nil {
			if n.optional {
				return nil
			}
			return err
		}
		return out(r)
	}
	if n.hasConstKey {
		k := n.b.val
		return eval(n.a, v, e, func(t value.Value) error {
			if t.Kind() == value.KindObject {
				r, _ := t.Object().Get(n.constKey)
				return out(r)
			}
			return step(t, k)
		})
	}
	return eval(n.b, v, e, func(k value.Value) error {
		return eval(n.a, v, e, func(t value.Value) error { return step(t, k) })
	})
}

// index returns t[k], or an error for an unsupported combination.
func index(t, k value.Value) (value.Value, error) {
	switch {
	case k.Kind() == value.KindString:
		switch t.Kind() {
		case value.KindObject:
			r, _ := t.Object().Get(k.Str())
			return r, nil
		case value.KindNull:
			return value.Null, nil
		}
		return value.Null, errorf("Cannot index %s with string %s", t.TypeName(), value.JSON(k))
	case k.Kind() == value.KindNumber:
		switch t.Kind() {
		case value.KindArray:
			elems := t.Elems()
			i := int(math.Trunc(k.Float()))
			if i < 0 {
				i += len(elems)
			}
			if i < 0 || i >= len(elems) {
				return value.Null, nil
			}
			return elems[i], nil
		case value.KindNull:
			return value.Null, nil
		}
		return value.Null, errorf("Cannot index %s with number", t.TypeName())
	}
	return value.Null, errorf("Cannot index %s with %s", t.TypeName(), k.TypeName())
}

// evalSlice implements T[A:B]: for each A, for each B, for each target.
func evalSlice(n *node, v value.Value, e *env, out sink) error {
	withBounds := func(from, to value.Value) error {
		return eval(n.a, v, e, func(t value.Value) error {
			r, err := slice(t, from, to)
			if err != nil {
				if n.optional {
					return nil
				}
				return err
			}
			return out(r)
		})
	}
	withFrom := func(from value.Value) error {
		if n.c == nil {
			return withBounds(from, value.Null)
		}
		return eval(n.c, v, e, func(to value.Value) error { return withBounds(from, to) })
	}
	if n.b == nil {
		return withFrom(value.Null)
	}
	return eval(n.b, v, e, withFrom)
}

// slice returns t[from:to] where null bounds mean "unbounded".
func slice(t, from, to value.Value) (value.Value, error) {
	if t.Kind() == value.KindNull {
		return value.Null, nil
	}
	if t.Kind() != value.KindArray && t.Kind() != value.KindString {
		return value.Null, errorf("Cannot index %s with object", t.TypeName())
	}
	if (from.Kind() != value.KindNull && from.Kind() != value.KindNumber) ||
		(to.Kind() != value.KindNull && to.Kind() != value.KindNumber) {
		return value.Null, errorf("Start and end indices of an array slice must be numbers")
	}
	if t.Kind() == value.KindArray {
		elems := t.Elems()
		lo, hi := sliceBounds(len(elems), from, to)
		return value.Array(append([]value.Value{}, elems[lo:hi]...)), nil
	}
	s := t.Str()
	n := utf8.RuneCountInString(s)
	lo, hi := sliceBounds(n, from, to)
	if n == len(s) { // ASCII
		return value.String(s[lo:hi]), nil
	}
	return value.String(s[runeOffset(s, lo):runeOffset(s, hi)]), nil
}

// sliceBounds resolves slice bounds against a length: negative bounds count
// from the end, both are clamped to [0, n] and hi is raised to lo.
func sliceBounds(n int, from, to value.Value) (lo, hi int) {
	flo, fhi := 0.0, float64(n)
	if from.Kind() == value.KindNumber {
		flo = math.Floor(from.Float())
		if flo < 0 {
			flo += float64(n)
		}
	}
	if to.Kind() == value.KindNumber {
		fhi = math.Ceil(to.Float())
		if fhi < 0 {
			fhi += float64(n)
		}
	}
	flo = math.Max(0, math.Min(flo, float64(n)))
	fhi = math.Max(0, math.Min(fhi, float64(n)))
	lo, hi = int(flo), int(fhi)
	if hi < lo {
		hi = lo
	}
	return lo, hi
}

// runeOffset returns the byte offset of the i-th code point of s.
func runeOffset(s string, i int) int {
	off := 0
	for ; i > 0 && off < len(s); i-- {
		_, size := utf8.DecodeRuneInString(s[off:])
		off += size
	}
	return off
}
