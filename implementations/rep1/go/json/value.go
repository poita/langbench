package jsoncanon

// Kind identifies the type of a JSON [Value].
type Kind uint8

// The kinds of JSON value.
const (
	Null Kind = iota
	False
	True
	Number
	String
	Array
	Object
)

func (k Kind) String() string {
	switch k {
	case Null:
		return "null"
	case False:
		return "false"
	case True:
		return "true"
	case Number:
		return "number"
	case String:
		return "string"
	case Array:
		return "array"
	case Object:
		return "object"
	}
	return "invalid"
}

// Value is a parsed JSON value. The zero Value is null.
//
// Strings are held decoded (as UTF-8) and numbers as canonical text. Objects
// keep every member in input order, duplicates included; canonical
// serialization is what removes duplicates.
type Value struct {
	kind Kind
	// text holds the decoded bytes of a string or the canonical text of a
	// number. It may alias the parser's input buffer.
	text []byte
	// kids holds array elements, or for objects alternating key (a String
	// value) and member value.
	kids []Value
}

// Kind returns the type of v.
func (v *Value) Kind() Kind { return v.kind }

// Str returns the decoded contents of a string value, or "" for other kinds.
func (v *Value) Str() string {
	if v.kind != String {
		return ""
	}
	return string(v.text)
}

// Num returns the canonical text of a number value (see [Canonicalize] for
// the rules), or "" for other kinds.
func (v *Value) Num() string {
	if v.kind != Number {
		return ""
	}
	return string(v.text)
}

// Len returns the number of elements of an array or the number of members of
// an object (counting duplicate keys), and 0 for other kinds.
func (v *Value) Len() int {
	switch v.kind {
	case Array:
		return len(v.kids)
	case Object:
		return len(v.kids) / 2
	}
	return 0
}

// Elem returns the i'th element of an array. It panics if v is not an array
// or i is out of range.
func (v *Value) Elem(i int) *Value {
	if v.kind != Array {
		panic("jsoncanon: Elem called on " + v.kind.String())
	}
	return &v.kids[i]
}

// Member returns the i'th member of an object in input order. It panics if v
// is not an object or i is out of range.
func (v *Value) Member(i int) (key string, val *Value) {
	if v.kind != Object {
		panic("jsoncanon: Member called on " + v.kind.String())
	}
	return string(v.kids[2*i].text), &v.kids[2*i+1]
}

// Lookup returns the value of the last member of an object with the given
// decoded key, matching the duplicate-key rule of the canonical form. It
// returns nil if v is not an object or has no such key.
func (v *Value) Lookup(key string) *Value {
	if v.kind != Object {
		return nil
	}
	for i := len(v.kids) - 2; i >= 0; i -= 2 {
		if string(v.kids[i].text) == key {
			return &v.kids[i+1]
		}
	}
	return nil
}
