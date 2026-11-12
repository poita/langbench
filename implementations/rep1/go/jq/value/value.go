// Package value defines the JSON data model used by the jq library: the
// Value type, an insertion-ordered immutable Object, the jq total ordering,
// and a JSON decoder and encoder written from scratch.
//
// A Value is one of the following Go types:
//
//	nil        JSON null
//	bool       JSON true / false
//	float64    JSON number (all numbers are IEEE-754 doubles)
//	string     JSON string (UTF-8)
//	[]Value    JSON array
//	*Object    JSON object
//
// Values are immutable: no function in this package modifies a Value it was
// given, and callers must not modify slices obtained from an array Value.
// Sharing values is therefore always safe and costs O(1).
package value

// Value is a JSON value; see the package documentation for the permitted
// dynamic types.
type Value = any

// Kind identifies the dynamic type of a Value, in jq's type ordering.
type Kind int

// The kinds, in ascending jq order.
const (
	KindNull Kind = iota
	KindFalse
	KindTrue
	KindNumber
	KindString
	KindArray
	KindObject
)

// KindOf returns the kind of v. It panics if v is not a valid Value.
func KindOf(v Value) Kind {
	switch x := v.(type) {
	case nil:
		return KindNull
	case bool:
		if x {
			return KindTrue
		}
		return KindFalse
	case float64:
		return KindNumber
	case string:
		return KindString
	case []Value:
		return KindArray
	case *Object:
		return KindObject
	}
	panic("value: invalid Value type")
}

// TypeName returns the jq type name of v: "null", "boolean", "number",
// "string", "array" or "object".
func TypeName(v Value) string {
	switch KindOf(v) {
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

// Truthy reports whether v counts as true: everything except null and false.
func Truthy(v Value) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	}
	return true
}
