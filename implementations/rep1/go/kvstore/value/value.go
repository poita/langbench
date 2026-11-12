// Package value implements Tessera's document value model: null, bool, int,
// string, list and object values, their binary serialisation, canonical
// one-line rendering, deep comparison, field-path access and the
// order-preserving index key encoding.
package value

import (
	"sort"
	"strings"
)

// Kind is the type of a Value. The numeric order of the kinds is the type rank
// used by comparisons and by the index key encoding.
type Kind uint8

// The six kinds of value, in type-rank order.
const (
	Null Kind = iota
	Bool
	Int
	String
	List
	Object
)

// String returns the lower-case name of the kind.
func (k Kind) String() string {
	switch k {
	case Null:
		return "null"
	case Bool:
		return "bool"
	case Int:
		return "int"
	case String:
		return "string"
	case List:
		return "list"
	case Object:
		return "object"
	}
	return "invalid"
}

// MaxDepth is the maximum nesting depth of a stored document.
const MaxDepth = 32

// Field is one named member of an object.
type Field struct {
	Name string
	Val  Value
}

// Value is a document value. The zero Value is null. Construct values with the
// helper functions (NullValue, BoolValue, IntValue, StringValue, ListValue,
// ObjectValue) or by deserialising them.
//
// A Value must be treated as immutable once built.
type Value struct {
	Kind   Kind
	I      int64   // Int value; 0 or 1 for Bool
	S      string  // String value
	Items  []Value // List elements
	Fields []Field // Object fields, sorted by ascending byte-wise name, names distinct
}

// NullValue returns the null value.
func NullValue() Value { return Value{} }

// BoolValue returns a bool value.
func BoolValue(b bool) Value {
	v := Value{Kind: Bool}
	if b {
		v.I = 1
	}
	return v
}

// IntValue returns an int value.
func IntValue(i int64) Value { return Value{Kind: Int, I: i} }

// StringValue returns a string value. The string is expected to be valid UTF-8.
func StringValue(s string) Value { return Value{Kind: String, S: s} }

// ListValue returns a list value holding items in order.
func ListValue(items ...Value) Value { return Value{Kind: List, Items: items} }

// ObjectValue returns an object value. Fields are sorted by name; if two
// fields share a name the later one wins.
func ObjectValue(fields ...Field) Value {
	fs := make([]Field, len(fields))
	copy(fs, fields)
	sort.SliceStable(fs, func(i, j int) bool { return fs[i].Name < fs[j].Name })
	out := fs[:0]
	for _, f := range fs {
		if n := len(out); n > 0 && out[n-1].Name == f.Name {
			out[n-1] = f
			continue
		}
		out = append(out, f)
	}
	return Value{Kind: Object, Fields: out}
}

// Bool reports the value of a bool Value.
func (v Value) Bool() bool { return v.I != 0 }

// Depth returns the nesting depth of v: 1 for scalars and for empty
// containers, otherwise 1 plus the depth of the deepest element.
func (v Value) Depth() int {
	max := 0
	switch v.Kind {
	case List:
		for i := range v.Items {
			if d := v.Items[i].Depth(); d > max {
				max = d
			}
		}
	case Object:
		for i := range v.Fields {
			if d := v.Fields[i].Val.Depth(); d > max {
				max = d
			}
		}
	}
	return 1 + max
}

// Field looks up an object field by name.
func (v Value) Field(name string) (Value, bool) {
	if v.Kind != Object {
		return Value{}, false
	}
	i := sort.Search(len(v.Fields), func(i int) bool { return v.Fields[i].Name >= name })
	if i < len(v.Fields) && v.Fields[i].Name == name {
		return v.Fields[i].Val, true
	}
	return Value{}, false
}

// Lookup resolves a field path against v. Only objects are traversed; a path
// into any other kind of value (including a list) is missing.
func (v Value) Lookup(path []string) (Value, bool) {
	cur := v
	for _, seg := range path {
		next, ok := cur.Field(seg)
		if !ok {
			return Value{}, false
		}
		cur = next
	}
	return cur, true
}

// Equal reports deep equality: same kind and same contents.
func Equal(a, b Value) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case Null:
		return true
	case Bool, Int:
		return a.I == b.I
	case String:
		return a.S == b.S
	case List:
		if len(a.Items) != len(b.Items) {
			return false
		}
		for i := range a.Items {
			if !Equal(a.Items[i], b.Items[i]) {
				return false
			}
		}
		return true
	case Object:
		if len(a.Fields) != len(b.Fields) {
			return false
		}
		for i := range a.Fields {
			if a.Fields[i].Name != b.Fields[i].Name || !Equal(a.Fields[i].Val, b.Fields[i].Val) {
				return false
			}
		}
		return true
	}
	return false
}

// Compare orders two scalar values of the same kind and returns -1, 0 or +1.
// ok is false when the kinds differ or either value is a list or an object,
// in which case no ordering is defined.
func Compare(a, b Value) (c int, ok bool) {
	if a.Kind != b.Kind || a.Kind >= List {
		return 0, false
	}
	switch a.Kind {
	case Null:
		return 0, true
	case Bool, Int:
		switch {
		case a.I < b.I:
			return -1, true
		case a.I > b.I:
			return 1, true
		}
		return 0, true
	case String:
		return strings.Compare(a.S, b.S), true
	}
	return 0, false
}

// PathError describes why Set or Unset failed.
type PathError int

// The reasons a path operation can fail.
const (
	// ErrNotObject: the path traverses a value that is not an object.
	ErrNotObject PathError = iota + 1
	// ErrNoField: the path names a field that does not exist.
	ErrNoField
)

func (e PathError) Error() string {
	switch e {
	case ErrNotObject:
		return "path traverses a value that is not an object"
	case ErrNoField:
		return "no such field"
	}
	return "path error"
}

// Set returns a copy of v in which the field at path holds nv. Missing
// intermediate fields are created as empty objects. It fails with
// ErrNotObject when v, or any existing value on the way, is not an object.
// path must not be empty.
func Set(v Value, path []string, nv Value) (Value, error) {
	if v.Kind != Object {
		return Value{}, ErrNotObject
	}
	name := path[0]
	i := sort.Search(len(v.Fields), func(i int) bool { return v.Fields[i].Name >= name })
	exists := i < len(v.Fields) && v.Fields[i].Name == name
	var child Value
	if len(path) == 1 {
		child = nv
	} else {
		cur := ObjectValue()
		if exists {
			cur = v.Fields[i].Val
		}
		var err error
		child, err = Set(cur, path[1:], nv)
		if err != nil {
			return Value{}, err
		}
	}
	var fs []Field
	if exists {
		fs = make([]Field, len(v.Fields))
		copy(fs, v.Fields)
		fs[i].Val = child
	} else {
		fs = make([]Field, 0, len(v.Fields)+1)
		fs = append(fs, v.Fields[:i]...)
		fs = append(fs, Field{name, child})
		fs = append(fs, v.Fields[i:]...)
	}
	return Value{Kind: Object, Fields: fs}, nil
}

// Unset returns a copy of v with the field at path removed. It fails with
// ErrNotObject when a traversed value is not an object and with ErrNoField when
// a field on the path is missing; the first failure along the path decides.
// path must not be empty.
func Unset(v Value, path []string) (Value, error) {
	if v.Kind != Object {
		return Value{}, ErrNotObject
	}
	name := path[0]
	i := sort.Search(len(v.Fields), func(i int) bool { return v.Fields[i].Name >= name })
	if i >= len(v.Fields) || v.Fields[i].Name != name {
		return Value{}, ErrNoField
	}
	if len(path) == 1 {
		fs := make([]Field, 0, len(v.Fields)-1)
		fs = append(fs, v.Fields[:i]...)
		fs = append(fs, v.Fields[i+1:]...)
		return Value{Kind: Object, Fields: fs}, nil
	}
	child, err := Unset(v.Fields[i].Val, path[1:])
	if err != nil {
		return Value{}, err
	}
	fs := make([]Field, len(v.Fields))
	copy(fs, v.Fields)
	fs[i].Val = child
	return Value{Kind: Object, Fields: fs}, nil
}
