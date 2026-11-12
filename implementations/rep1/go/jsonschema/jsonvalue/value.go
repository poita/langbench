// Package jsonvalue provides an immutable JSON data model with exact decimal
// numbers, a strict RFC 8259 parser, and structural JSON equality and hashing.
//
// It exists because JSON Schema validation needs semantics that
// encoding/json does not offer: numbers are exact rationals (1, 1.0 and 1e0
// are the same number, and nothing is ever rounded to a float64), objects
// keep their members in document order, and equality ignores member order.
package jsonvalue

import "strconv"

// Kind identifies the type of a Value.
type Kind uint8

// The JSON value kinds. Integers are not a separate kind: a Number is an
// integer when Number.IsInteger reports so.
const (
	Null Kind = iota
	Bool
	NumberKind
	String
	Array
	ObjectKind
)

func (k Kind) String() string {
	switch k {
	case Null:
		return "null"
	case Bool:
		return "boolean"
	case NumberKind:
		return "number"
	case String:
		return "string"
	case Array:
		return "array"
	case ObjectKind:
		return "object"
	}
	return "invalid"
}

// Value is a JSON value. The zero Value is null. Values are small and are
// passed by value; they share their underlying arrays and objects, which
// must not be modified.
type Value struct {
	kind Kind
	b    bool
	s    string
	a    []Value
	o    *Object
	n    *Number
}

// Constructors.

// NullValue returns the JSON null.
func NullValue() Value { return Value{} }

// BoolValue returns a JSON boolean.
func BoolValue(b bool) Value { return Value{kind: Bool, b: b} }

// NumberValue returns a JSON number.
func NumberValue(n Number) Value { return Value{kind: NumberKind, n: &n} }

// StringValue returns a JSON string.
func StringValue(s string) Value { return Value{kind: String, s: s} }

// ArrayValue returns a JSON array holding elems (the slice is not copied).
func ArrayValue(elems []Value) Value { return Value{kind: Array, a: elems} }

// ObjectValue returns a JSON object holding the given members in order.
// keys and vals must have equal length and keys must be distinct; neither
// slice is copied.
func ObjectValue(keys []string, vals []Value) Value {
	return Value{kind: ObjectKind, o: newObject(keys, vals)}
}

// Accessors.

// Kind returns the kind of v.
func (v Value) Kind() Kind { return v.kind }

// IsNull reports whether v is null.
func (v Value) IsNull() bool { return v.kind == Null }

// Bool returns the boolean held by v and whether v is a boolean.
func (v Value) Bool() (bool, bool) { return v.b, v.kind == Bool }

// Number returns the number held by v and whether v is a number.
func (v Value) Number() (Number, bool) {
	if v.kind != NumberKind {
		return Number{}, false
	}
	return *v.n, true
}

// Str returns the string held by v and whether v is a string.
func (v Value) Str() (string, bool) { return v.s, v.kind == String }

// Array returns the elements of v and whether v is an array. The slice must
// not be modified.
func (v Value) Array() ([]Value, bool) { return v.a, v.kind == Array }

// Object returns the object held by v and whether v is an object.
func (v Value) Object() (*Object, bool) { return v.o, v.kind == ObjectKind }

// Object is a JSON object whose members keep their document order.
type Object struct {
	keys []string
	vals []Value
	idx  map[string]int // built for larger objects only
}

const linearLookupMax = 8

func newObject(keys []string, vals []Value) *Object {
	o := &Object{keys: keys, vals: vals}
	if len(keys) > linearLookupMax {
		o.idx = make(map[string]int, len(keys))
		for i, k := range keys {
			o.idx[k] = i
		}
	}
	return o
}

// Len returns the number of members.
func (o *Object) Len() int { return len(o.keys) }

// Get returns the value of the member called name.
func (o *Object) Get(name string) (Value, bool) {
	if o.idx != nil {
		if i, ok := o.idx[name]; ok {
			return o.vals[i], true
		}
		return Value{}, false
	}
	for i, k := range o.keys {
		if k == name {
			return o.vals[i], true
		}
	}
	return Value{}, false
}

// Has reports whether the object has a member called name.
func (o *Object) Has(name string) bool {
	_, ok := o.Get(name)
	return ok
}

// At returns the i'th member in document order.
func (o *Object) At(i int) (string, Value) { return o.keys[i], o.vals[i] }

// Keys returns the member names in document order. The slice must not be
// modified.
func (o *Object) Keys() []string { return o.keys }

// SyntaxError describes malformed JSON input.
type SyntaxError struct {
	Msg    string
	Offset int // byte offset of the error in the input, or -1 if unknown
}

func (e *SyntaxError) Error() string {
	if e.Offset >= 0 {
		return "json: " + e.Msg + " at offset " + strconv.Itoa(e.Offset)
	}
	return "json: " + e.Msg
}

func quote(s string) string { return strconv.Quote(s) }
func itoa(n int) string     { return strconv.Itoa(n) }
