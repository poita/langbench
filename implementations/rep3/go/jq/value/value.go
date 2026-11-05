// Package value defines the immutable JSON value model used by the jq
// interpreter, together with a JSON parser, a compact JSON encoder and the
// total ordering jq applies to values.
//
// A Value is a small tagged struct: null, booleans and numbers are stored
// inline, while strings, arrays and objects hold a reference to immutable
// heap data. Copying a Value never copies the underlying contents. Callers
// must treat arrays returned by Array and objects returned by Object as
// read-only.
package value

// Kind identifies the dynamic type of a Value. The numeric order of the
// kinds is the type order used when comparing values of different types.
type Kind uint8

// The kinds of JSON value, in jq's type order.
const (
	KindNull Kind = iota
	KindFalse
	KindTrue
	KindNumber
	KindString
	KindArray
	KindObject
)

// Value is an immutable JSON value. The zero Value is null.
type Value struct {
	kind Kind
	num  float64
	ref  any // string, []Value or *Object
}

// Predefined scalar values.
var (
	Null  = Value{}
	True  = Value{kind: KindTrue}
	False = Value{kind: KindFalse}
)

// Number returns a number value.
func Number(f float64) Value { return Value{kind: KindNumber, num: f} }

// String returns a string value.
func String(s string) Value { return Value{kind: KindString, ref: s} }

// Bool returns True or False.
func Bool(b bool) Value {
	if b {
		return True
	}
	return False
}

// Array returns an array value that takes ownership of items; the caller must
// not modify the slice afterwards.
func Array(items []Value) Value { return Value{kind: KindArray, ref: items} }

// ObjectValue wraps an object. The object must not be modified afterwards.
func ObjectValue(o *Object) Value { return Value{kind: KindObject, ref: o} }

// Kind returns the dynamic type of v.
func (v Value) Kind() Kind { return v.kind }

// IsNull reports whether v is null.
func (v Value) IsNull() bool { return v.kind == KindNull }

// IsNumber reports whether v is a number.
func (v Value) IsNumber() bool { return v.kind == KindNumber }

// IsString reports whether v is a string.
func (v Value) IsString() bool { return v.kind == KindString }

// IsArray reports whether v is an array.
func (v Value) IsArray() bool { return v.kind == KindArray }

// IsObject reports whether v is an object.
func (v Value) IsObject() bool { return v.kind == KindObject }

// Truthy reports whether v counts as true: everything except false and null.
func (v Value) Truthy() bool { return v.kind != KindNull && v.kind != KindFalse }

// Float returns the number held by v (0 if v is not a number).
func (v Value) Float() float64 { return v.num }

// Str returns the string held by v ("" if v is not a string).
func (v Value) Str() string {
	s, _ := v.ref.(string)
	return s
}

// Items returns the elements of an array value (nil for other kinds). The
// result must not be modified.
func (v Value) Items() []Value {
	a, _ := v.ref.([]Value)
	return a
}

// Obj returns the object held by v (nil for other kinds). The result must not
// be modified.
func (v Value) Obj() *Object {
	o, _ := v.ref.(*Object)
	return o
}

// TypeName returns jq's name for the type of v.
func (v Value) TypeName() string {
	switch v.kind {
	case KindNull:
		return "null"
	case KindFalse, KindTrue:
		return "boolean"
	case KindNumber:
		return "number"
	case KindString:
		return "string"
	case KindArray:
		return "array"
	}
	return "object"
}
