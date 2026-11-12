// Package jq implements a subset of the jq query language: a JSON parser and
// serializer, a filter parser, and a lazy, streaming tree-walking evaluator.
//
// # Values
//
// JSON values are represented by the Value type (an alias for any) holding
// one of:
//
//	nil        JSON null
//	bool       true / false
//	float64    every JSON number
//	string     JSON strings (UTF-8)
//	[]Value    arrays
//	*Object    objects, which remember insertion order
//
// Values are immutable once built: no operation in this package modifies a
// value it was given, so values may be shared freely (including between
// goroutines, provided Object.Set is not called after sharing).
//
// # Typical use
//
//	f, err := jq.Compile(`.users | map(select(.age >= 30)) | length`)
//	doc, err := jq.ParseJSON(data)
//	err = f.Run(doc, func(v jq.Value) error {
//		fmt.Println(string(jq.Marshal(v)))
//		return nil
//	})
package jq

// Value is any JSON value; see the package documentation for the concrete types.
type Value = any

// TypeName returns the jq type name of v: "null", "boolean", "number",
// "string", "array" or "object".
func TypeName(v Value) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case float64:
		return "number"
	case string:
		return "string"
	case []Value:
		return "array"
	case *Object:
		return "object"
	}
	return "unknown"
}

// Truthy reports whether v counts as true in a condition: everything except
// null and false.
func Truthy(v Value) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	}
	return true
}
