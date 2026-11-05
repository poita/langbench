// Package value implements the Tessera document model: null, bool, 64-bit
// int, string, list and object values, with their binary serialisation,
// canonical one-line rendering, deep comparison and field-path access.
package value

import (
	"sort"
	"strings"
)

// Kind is the type of a value. The numeric order is the specification's type
// rank, used by comparisons and index keys.
type Kind uint8

// The six value kinds, in type-rank order.
const (
	Null Kind = iota
	Bool
	Int
	String
	List
	Object
)

// Field is one named member of an object.
type Field struct {
	Name  string
	Value Value
}

// Value is a document value. Only the members relevant to Kind are used.
// Object fields are always kept sorted by name (byte-wise) with distinct names.
type Value struct {
	Kind   Kind
	Bool   bool
	Int    int64
	Str    string
	List   []Value
	Fields []Field
}

// NewNull returns the null value.
func NewNull() Value { return Value{Kind: Null} }

// NewBool returns a bool value.
func NewBool(b bool) Value { return Value{Kind: Bool, Bool: b} }

// NewInt returns an int value.
func NewInt(i int64) Value { return Value{Kind: Int, Int: i} }

// NewString returns a string value.
func NewString(s string) Value { return Value{Kind: String, Str: s} }

// NewList returns a list value holding elems.
func NewList(elems []Value) Value { return Value{Kind: List, List: elems} }

// NewObject returns an object holding fields. The names must be distinct; the
// fields are sorted into canonical order.
func NewObject(fields []Field) Value {
	fs := make([]Field, len(fields))
	copy(fs, fields)
	sort.Slice(fs, func(i, j int) bool { return fs[i].Name < fs[j].Name })
	return Value{Kind: Object, Fields: fs}
}

// Depth returns the nesting depth of v: 1 for scalars and for empty
// containers, otherwise 1 plus the maximum depth of the members.
func (v Value) Depth() int {
	max := 0
	switch v.Kind {
	case List:
		for _, e := range v.List {
			if d := e.Depth(); d > max {
				max = d
			}
		}
	case Object:
		for _, f := range v.Fields {
			if d := f.Value.Depth(); d > max {
				max = d
			}
		}
	default:
		return 1
	}
	return 1 + max
}

// field finds the index of the field called name using binary search.
func (v Value) field(name string) (int, bool) {
	i := sort.Search(len(v.Fields), func(i int) bool { return v.Fields[i].Name >= name })
	return i, i < len(v.Fields) && v.Fields[i].Name == name
}

// Get returns the value of the object field called name.
func (v Value) Get(name string) (Value, bool) {
	if v.Kind != Object {
		return Value{}, false
	}
	if i, ok := v.field(name); ok {
		return v.Fields[i].Value, true
	}
	return Value{}, false
}

// Equal reports whether a and b have the same kind and are deeply equal.
func Equal(a, b Value) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case Null:
		return true
	case Bool:
		return a.Bool == b.Bool
	case Int:
		return a.Int == b.Int
	case String:
		return a.Str == b.Str
	case List:
		if len(a.List) != len(b.List) {
			return false
		}
		for i := range a.List {
			if !Equal(a.List[i], b.List[i]) {
				return false
			}
		}
		return true
	default:
		if len(a.Fields) != len(b.Fields) {
			return false
		}
		for i := range a.Fields {
			if a.Fields[i].Name != b.Fields[i].Name || !Equal(a.Fields[i].Value, b.Fields[i].Value) {
				return false
			}
		}
		return true
	}
}

// Compare orders two scalar values of the same kind (-1, 0 or +1). ok is
// false when the kinds differ or either value is a list or an object, in
// which case no ordering is defined.
func Compare(a, b Value) (c int, ok bool) {
	if a.Kind != b.Kind {
		return 0, false
	}
	switch a.Kind {
	case Null:
		return 0, true
	case Bool:
		switch {
		case a.Bool == b.Bool:
			return 0, true
		case !a.Bool:
			return -1, true
		}
		return 1, true
	case Int:
		switch {
		case a.Int < b.Int:
			return -1, true
		case a.Int > b.Int:
			return 1, true
		}
		return 0, true
	case String:
		return strings.Compare(a.Str, b.Str), true
	}
	return 0, false
}
