// Package value defines the immutable JSON value model used by the jq
// interpreter, together with its total ordering, JSON parser and JSON
// serialiser.
//
// A Value is a small tagged struct. Null, booleans and numbers are stored
// inline; strings, arrays and objects are held by reference to immutable
// data, so copying a Value never copies the contents of a container.
// Operations that "change" a container build a new one that shares the
// unchanged children.
package value

// Kind identifies the dynamic type of a Value. The numeric order of the
// constants is the jq type order: null < false < true < numbers < strings <
// arrays < objects.
type Kind uint8

// The kinds of Value, in type-order.
const (
	KindNull Kind = iota
	KindFalse
	KindTrue
	KindNumber
	KindString
	KindArray
	KindObject
)

// TypeName returns the jq type name ("null", "boolean", "number", ...).
func (k Kind) TypeName() string {
	switch k {
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
	default:
		return "object"
	}
}

// Value is an immutable JSON value. The zero Value is null.
type Value struct {
	kind Kind
	num  float64
	ref  any // string, []Value or *Object depending on kind
}

// Common constant values.
var (
	Null  = Value{}
	True  = Value{kind: KindTrue}
	False = Value{kind: KindFalse}
)

// Bool returns True or False.
func Bool(b bool) Value {
	if b {
		return True
	}
	return False
}

// Number returns a number value.
func Number(f float64) Value { return Value{kind: KindNumber, num: f} }

// String returns a string value.
func String(s string) Value { return Value{kind: KindString, ref: s} }

// Array returns an array value that takes ownership of elems: the caller must
// not modify the slice afterwards.
func Array(elems []Value) Value { return Value{kind: KindArray, ref: elems} }

// Kind returns the dynamic type of v.
func (v Value) Kind() Kind { return v.kind }

// TypeName returns the jq type name of v.
func (v Value) TypeName() string { return v.kind.TypeName() }

// IsNull reports whether v is null.
func (v Value) IsNull() bool { return v.kind == KindNull }

// Truthy reports whether v counts as true in a condition: everything except
// false and null.
func (v Value) Truthy() bool { return v.kind > KindFalse }

// Float returns the numeric value of a number, or 0 for other kinds.
func (v Value) Float() float64 { return v.num }

// Str returns the contents of a string, or "" for other kinds.
func (v Value) Str() string {
	s, _ := v.ref.(string)
	return s
}

// Elems returns the elements of an array (nil for other kinds). The result is
// shared and must not be modified.
func (v Value) Elems() []Value {
	if v.kind != KindArray {
		return nil
	}
	e, _ := v.ref.([]Value)
	return e
}

// Object returns the object behind v, or nil if v is not an object.
func (v Value) Object() *Object {
	o, _ := v.ref.(*Object)
	return o
}
