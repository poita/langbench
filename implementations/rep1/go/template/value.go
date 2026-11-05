package template

import "unicode/utf8"

// Value is a template value. The dynamic type is one of:
//
//	Undefined   the undefined value (see IsUndefined)
//	None        the none value
//	bool        boolean
//	int64       integer
//	float64     float
//	string      string (UTF-8)
//	*List       list
//	*Dict       dict with string keys in insertion order
//
// plus a few internal kinds (macros, the range builtin, super and loop
// records) that templates can produce but callers normally never see.
// Lists, dicts and strings are immutable once built and are shared by
// reference, so copying a Value is O(1).
type Value = any

type undefinedType struct{}
type noneType struct{}

// unboundType marks a macro parameter slot that has not been bound yet.
type unboundType struct{}

// Undefined is the template "undefined" value.
var Undefined Value = undefinedType{}

// None is the template "none" value (JSON null).
var None Value = noneType{}

var unbound Value = unboundType{}

// IsUndefined reports whether v is the undefined value.
func IsUndefined(v Value) bool {
	_, ok := v.(undefinedType)
	return ok
}

// List is a template list. Treat Items as read-only once the list has been
// handed to a render.
type List struct {
	Items []Value
}

// NewList returns a list holding the given items (not copied).
func NewList(items ...Value) *List { return &List{Items: items} }

// dictIndexThreshold is the size above which a Dict maintains a hash index;
// smaller dicts are searched linearly.
const dictIndexThreshold = 8

// Dict is an insertion-ordered map with string keys.
type Dict struct {
	keys []string
	vals []Value
	idx  map[string]int
}

// NewDict returns an empty dict with room for capacity members.
func NewDict(capacity int) *Dict {
	return &Dict{keys: make([]string, 0, capacity), vals: make([]Value, 0, capacity)}
}

// Len returns the number of members.
func (d *Dict) Len() int { return len(d.keys) }

// Keys returns the keys in insertion order. The slice must not be modified.
func (d *Dict) Keys() []string { return d.keys }

// At returns the i-th member in insertion order.
func (d *Dict) At(i int) (string, Value) { return d.keys[i], d.vals[i] }

func (d *Dict) find(k string) int {
	if d.idx != nil {
		if i, ok := d.idx[k]; ok {
			return i
		}
		return -1
	}
	for i, kk := range d.keys {
		if kk == k {
			return i
		}
	}
	return -1
}

// Get returns the value stored under k.
func (d *Dict) Get(k string) (Value, bool) {
	if i := d.find(k); i >= 0 {
		return d.vals[i], true
	}
	return nil, false
}

// Set stores v under k, appending the key if it is new. A Dict must not be
// modified after it has been passed to a render.
func (d *Dict) Set(k string, v Value) {
	if i := d.find(k); i >= 0 {
		d.vals[i] = v
		return
	}
	d.keys = append(d.keys, k)
	d.vals = append(d.vals, v)
	if d.idx != nil {
		d.idx[k] = len(d.keys) - 1
	} else if len(d.keys) > dictIndexThreshold {
		d.idx = make(map[string]int, len(d.keys)*2)
		for i, kk := range d.keys {
			d.idx[kk] = i
		}
	}
}

// numKind classifies the numeric kinds. Booleans count as integers.
type numKind uint8

const (
	nkNone numKind = iota
	nkInt
	nkFloat
)

// num extracts the numeric content of v. For nkInt the integer is returned
// in i; for nkFloat the float is returned in f.
func num(v Value) (i int64, f float64, k numKind) {
	switch x := v.(type) {
	case int64:
		return x, 0, nkInt
	case float64:
		return 0, x, nkFloat
	case bool:
		if x {
			return 1, 0, nkInt
		}
		return 0, 0, nkInt
	}
	return 0, 0, nkNone
}

func asFloat(i int64, f float64, k numKind) float64 {
	if k == nkInt {
		return float64(i)
	}
	return f
}

// truthy implements template truthiness. The undefined value is an error.
func truthy(v Value) bool {
	switch x := v.(type) {
	case bool:
		return x
	case int64:
		return x != 0
	case float64:
		return x != 0
	case string:
		return x != ""
	case *List:
		return len(x.Items) > 0
	case *Dict:
		return x.Len() > 0
	case noneType:
		return false
	case undefinedType:
		throw(ErrUndefined, "truthiness of undefined value")
	}
	return true
}

// valuesEqual implements the == operator for two defined values.
func valuesEqual(a, b Value) bool {
	if ai, af, ak := num(a); ak != nkNone {
		bi, bf, bk := num(b)
		switch {
		case bk == nkNone:
			return false
		case ak == nkInt && bk == nkInt:
			return ai == bi
		default:
			return asFloat(ai, af, ak) == asFloat(bi, bf, bk)
		}
	}
	switch x := a.(type) {
	case string:
		y, ok := b.(string)
		return ok && x == y
	case noneType:
		_, ok := b.(noneType)
		return ok
	case *List:
		y, ok := b.(*List)
		if !ok {
			return false
		}
		if x == y {
			return true
		}
		if len(x.Items) != len(y.Items) {
			return false
		}
		for i := range x.Items {
			if !valuesEqual(x.Items[i], y.Items[i]) {
				return false
			}
		}
		return true
	case *Dict:
		y, ok := b.(*Dict)
		if !ok {
			return false
		}
		if x == y {
			return true
		}
		if x.Len() != y.Len() {
			return false
		}
		for i, k := range x.keys {
			yv, ok := y.Get(k)
			if !ok || !valuesEqual(x.vals[i], yv) {
				return false
			}
		}
		return true
	}
	return a == b
}

// loopRec is the value bound to "loop" inside a for body.
type loopRec struct {
	index0 int
	length int
}

func (l *loopRec) get(key string) Value {
	switch key {
	case "index":
		return int64(l.index0 + 1)
	case "index0":
		return int64(l.index0)
	case "first":
		return l.index0 == 0
	case "last":
		return l.index0 == l.length-1
	case "length":
		return int64(l.length)
	}
	return Undefined
}

// rangeFn is the built-in range function.
type rangeFn struct{}

var rangeBuiltin Value = &rangeFn{}

// seqView returns the sequence view of v: a list's elements, a dict's keys
// or a string's characters. Lists are returned without copying.
func seqView(v Value) []Value {
	switch x := v.(type) {
	case *List:
		return x.Items
	case *Dict:
		out := make([]Value, len(x.keys))
		for i, k := range x.keys {
			out[i] = k
		}
		return out
	case string:
		out := make([]Value, 0, len(x))
		for i, r := range x {
			out = append(out, x[i:i+utf8.RuneLen(r)])
		}
		return out
	case undefinedType:
		throw(ErrUndefined, "iterating over undefined value")
	}
	throw(ErrType, "value is not a sequence")
	return nil
}
