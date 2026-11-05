// Package value defines the immutable data model used by the jq
// interpreter: null, booleans, numbers (IEEE doubles), strings, arrays and
// insertion-ordered objects.
//
// A Value is a small three-word struct. Null, booleans and numbers are stored
// inline; strings and arrays are stored as a (pointer, length) pair that
// aliases the underlying Go string or slice; objects are a pointer to an
// Object. Copying a Value therefore never copies string, array or object
// contents.
//
// Values are immutable. The only mutable thing in this package is a
// *Object obtained from NewObject, and only until it has been wrapped with
// ObjectValue and published. A Value must not be shared between goroutines
// while it is still being used for the first time, because objects build their
// lookup index and sorted-key order lazily.
package value

import (
	"math"
	"unsafe"
)

// Kind is the dynamic type of a Value. The numeric order of the kinds is the
// order used when comparing values of different types:
// null < false < true < numbers < strings < arrays < objects.
type Kind uint8

// The kinds of value, in comparison order.
const (
	KindNull Kind = iota
	KindFalse
	KindTrue
	KindNumber
	KindString
	KindArray
	KindObject
)

// TypeName returns the jq type name of the kind ("null", "boolean",
// "number", "string", "array" or "object").
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
	}
	return "object"
}

// Value is a JSON value. The zero Value is null.
type Value struct {
	p unsafe.Pointer // string data, first array element, or *Object
	x uint64         // float64 bits (number) or length (string, array)
	k Kind
}

// Null is the null value.
var Null = Value{}

// True and False are the boolean values.
var (
	True  = Value{k: KindTrue}
	False = Value{k: KindFalse}
)

// Bool returns True or False.
func Bool(b bool) Value {
	if b {
		return True
	}
	return False
}

// Number returns a number value.
func Number(f float64) Value { return Value{x: math.Float64bits(f), k: KindNumber} }

// String returns a string value. The string is not copied.
func String(s string) Value {
	return Value{p: unsafe.Pointer(unsafe.StringData(s)), x: uint64(len(s)), k: KindString}
}

// Array returns an array value backed by elems. The slice is not copied:
// the caller must not modify it afterwards.
func Array(elems []Value) Value {
	return Value{p: unsafe.Pointer(unsafe.SliceData(elems)), x: uint64(len(elems)), k: KindArray}
}

// ObjectValue wraps o as a value. The caller must not mutate o afterwards.
func ObjectValue(o *Object) Value { return Value{p: unsafe.Pointer(o), k: KindObject} }

// Kind returns the dynamic type of v.
func (v Value) Kind() Kind { return v.k }

// TypeName returns the jq type name of v.
func (v Value) TypeName() string { return v.k.TypeName() }

// IsNull reports whether v is null.
func (v Value) IsNull() bool { return v.k == KindNull }

// Truthy reports whether v counts as true in a condition: everything except
// null and false.
func (v Value) Truthy() bool { return v.k > KindFalse }

// Float returns the number held by v, or 0 if v is not a number.
func (v Value) Float() float64 {
	if v.k != KindNumber {
		return 0
	}
	return math.Float64frombits(v.x)
}

// Str returns the string held by v, or "" if v is not a string.
func (v Value) Str() string {
	if v.k != KindString {
		return ""
	}
	return unsafe.String((*byte)(v.p), int(v.x))
}

// Elems returns the elements of an array value (nil for other kinds). The
// returned slice must not be modified.
func (v Value) Elems() []Value {
	if v.k != KindArray {
		return nil
	}
	return unsafe.Slice((*Value)(v.p), int(v.x))
}

// Obj returns the object held by v, or nil if v is not an object. The
// returned object must not be modified.
func (v Value) Obj() *Object {
	if v.k != KindObject {
		return nil
	}
	return (*Object)(v.p)
}

// Error is the error type raised by jq operations (type errors, division by
// zero, explicit error(...) calls).
type Error struct {
	// Msg is a human-readable description.
	Msg string
	// Payload is the value passed to error(f); null for built-in errors.
	Payload Value
}

func (e *Error) Error() string { return e.Msg }

// NewError returns an *Error with the given message.
func NewError(msg string) *Error { return &Error{Msg: msg} }
