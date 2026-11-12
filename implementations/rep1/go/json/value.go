package jsoncanon

// Kind identifies the type of a [Value].
type Kind uint8

// The kinds of JSON value.
const (
	Null Kind = iota
	Bool
	Number
	String
	Array
	Object
)

func (k Kind) String() string {
	switch k {
	case Null:
		return "null"
	case Bool:
		return "bool"
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

// Member is one key/value pair of an object.
type Member struct {
	Key   string // decoded key (valid UTF-8)
	Value Value
}

// Value is a node of a parsed JSON document.
//
// Which fields are meaningful depends on Kind:
//
//	Null:   none
//	Bool:   Bool
//	Number: Text, the number in canonical textual form (see [Parse])
//	String: Text, the decoded string (valid UTF-8)
//	Array:  Elems, in input order
//	Object: Members, in input order, duplicate keys included
type Value struct {
	Kind    Kind
	Bool    bool
	Text    string
	Elems   []Value
	Members []Member
}
