// Package value defines the dynamic values manipulated by templates and the
// operations on them: printing, truthiness, equality, ordering, arithmetic,
// attribute access and the sequence view.
//
// A [Value] is an ordinary Go value of one of these dynamic types:
//
//	int64        integer
//	float64      float
//	bool         boolean
//	string       string (a sequence of Unicode code points)
//	NoneType     none
//	*List        list
//	*Dict        dict with insertion-ordered string keys
//	*Loop        the `loop` variable of a for body
//	Callable     a macro, `range` or `super`
//	UndefinedType the undefined value
//
// Values are immutable once built and are shared, never copied.
package value

// Value is any template value; see the package documentation for the
// permitted dynamic types.
type Value = any

// NoneType is the type of the none value.
type NoneType struct{}

// UndefinedType is the type of the undefined value.
type UndefinedType struct{}

// None is the none value.
var None Value = NoneType{}

// Undefined is the undefined value.
var Undefined Value = UndefinedType{}

// IsUndefined reports whether v is the undefined value.
func IsUndefined(v Value) bool {
	_, ok := v.(UndefinedType)
	return ok
}

// Callable is implemented by the values that can be called: macros, the
// built-in range, and super.
type Callable interface {
	CallableName() string
}

// List is a list value. Items must not be modified once the list has been
// handed to the engine.
type List struct {
	Items []Value
}

// NewList returns a list holding items.
func NewList(items []Value) *List { return &List{Items: items} }

// Loop is the value bound to `loop` inside a for body.
type Loop struct {
	Index0 int // 0-based position
	Length int // number of elements
}

// Member returns the loop member with the given name (index, index0, first,
// last or length) and whether it exists.
func (l *Loop) Member(name string) (Value, bool) {
	switch name {
	case "index":
		return int64(l.Index0 + 1), true
	case "index0":
		return int64(l.Index0), true
	case "first":
		return l.Index0 == 0, true
	case "last":
		return l.Index0 == l.Length-1, true
	case "length":
		return int64(l.Length), true
	}
	return nil, false
}

// Dict is an insertion-ordered mapping from string keys to values. Small
// dicts are searched linearly; larger ones carry a hash index.
type Dict struct {
	keys []string
	vals []Value
	idx  map[string]int
}

const dictIndexThreshold = 8

// NewDict returns an empty dict with room for capacity members.
func NewDict(capacity int) *Dict {
	return &Dict{keys: make([]string, 0, capacity), vals: make([]Value, 0, capacity)}
}

// Len returns the number of members.
func (d *Dict) Len() int { return len(d.keys) }

// Keys returns the keys in insertion order. The slice must not be modified.
func (d *Dict) Keys() []string { return d.keys }

// ValueAt returns the value of the i-th member in insertion order.
func (d *Dict) ValueAt(i int) Value { return d.vals[i] }

func (d *Dict) find(key string) int {
	if d.idx != nil {
		if i, ok := d.idx[key]; ok {
			return i
		}
		return -1
	}
	for i, k := range d.keys {
		if k == key {
			return i
		}
	}
	return -1
}

// Get returns the value stored under key.
func (d *Dict) Get(key string) (Value, bool) {
	if i := d.find(key); i >= 0 {
		return d.vals[i], true
	}
	return nil, false
}

// Set stores v under key. An existing key keeps its position.
func (d *Dict) Set(key string, v Value) {
	if i := d.find(key); i >= 0 {
		d.vals[i] = v
		return
	}
	d.keys = append(d.keys, key)
	d.vals = append(d.vals, v)
	switch {
	case d.idx != nil:
		d.idx[key] = len(d.keys) - 1
	case len(d.keys) > dictIndexThreshold:
		d.idx = make(map[string]int, len(d.keys)*2)
		for i, k := range d.keys {
			d.idx[k] = i
		}
	}
}
