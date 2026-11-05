package toml

import (
	"sort"
	"strconv"
)

// Kind identifies the type of a [Node].
type Kind uint8

// The node kinds. The scalar kinds correspond to the type names of the tagged
// JSON format.
const (
	Table         Kind = iota + 1 // a table: keys mapping to nodes
	Array                         // an array of nodes
	String                        // a string
	Integer                       // a 64-bit signed integer
	Float                         // an IEEE-754 binary64 float
	Bool                          // true or false
	DateTime                      // offset date-time
	DateTimeLocal                 // local date-time
	DateLocal                     // local date
	TimeLocal                     // local time

	kindRaw // internal: a bare JSON string while reading tagged JSON
)

var kindNames = [...]string{
	Table:         "table",
	Array:         "array",
	String:        "string",
	Integer:       "integer",
	Float:         "float",
	Bool:          "bool",
	DateTime:      "datetime",
	DateTimeLocal: "datetime-local",
	DateLocal:     "date-local",
	TimeLocal:     "time-local",
	kindRaw:       "raw",
}

// String returns the tagged-JSON type name of a scalar kind ("integer",
// "datetime-local", ...), or "table" / "array".
func (k Kind) String() string {
	if int(k) < len(kindNames) && kindNames[k] != "" {
		return kindNames[k]
	}
	return "invalid"
}

// kindByName maps tagged-JSON type names to scalar kinds.
func kindByName(s string) (Kind, bool) {
	switch s {
	case "string":
		return String, true
	case "integer":
		return Integer, true
	case "float":
		return Float, true
	case "bool":
		return Bool, true
	case "datetime":
		return DateTime, true
	case "datetime-local":
		return DateTimeLocal, true
	case "date-local":
		return DateLocal, true
	case "time-local":
		return TimeLocal, true
	}
	return 0, false
}

// Provenance flags used by the parser to enforce the table rules of TOML.
const (
	flagExplicit uint8 = 1 << iota // opened by [header] (or an inline-table literal)
	flagDotted                     // created as an intermediate segment of a dotted key
	flagSealed                     // part of an inline table literal: closed to extension
	flagAoT                        // array created by [[header]]
)

// Node is one element of a TOML document tree: a table, an array or a scalar.
//
// Scalar nodes store their canonical text (see the package documentation);
// use the typed accessors [Node.Int], [Node.Float], [Node.Bool] to get Go values.
type Node struct {
	kind  Kind
	flags uint8
	text  string
	tbl   map[string]*Node
	arr   []*Node
}

// NewTable returns an empty table node.
func NewTable() *Node { return &Node{kind: Table, tbl: make(map[string]*Node)} }

// NewArray returns an array node holding elems.
func NewArray(elems ...*Node) *Node { return &Node{kind: Array, arr: elems} }

// NewScalar returns a scalar node of the given kind holding the canonical text
// of its value. The text is not validated.
func NewScalar(kind Kind, text string) *Node { return &Node{kind: kind, text: text} }

// NewString returns a string node.
func NewString(s string) *Node { return NewScalar(String, s) }

// NewInt returns an integer node.
func NewInt(v int64) *Node { return NewScalar(Integer, strconv.FormatInt(v, 10)) }

// NewBool returns a bool node.
func NewBool(v bool) *Node { return NewScalar(Bool, strconv.FormatBool(v)) }

// NewFloat returns a float node holding v in canonical text form.
func NewFloat(v float64) *Node { return NewScalar(Float, formatFloat(v)) }

// Kind returns the kind of the node.
func (n *Node) Kind() Kind { return n.kind }

// IsTable reports whether n is a table.
func (n *Node) IsTable() bool { return n.kind == Table }

// IsArray reports whether n is an array.
func (n *Node) IsArray() bool { return n.kind == Array }

// Text returns the canonical text of a scalar node (the string itself for a
// String node). It is empty for tables and arrays.
func (n *Node) Text() string { return n.text }

// Int returns the value of an Integer node.
func (n *Node) Int() (int64, bool) {
	if n.kind != Integer {
		return 0, false
	}
	v, err := strconv.ParseInt(n.text, 10, 64)
	return v, err == nil
}

// Float returns the value of a Float node.
func (n *Node) Float() (float64, bool) {
	if n.kind != Float {
		return 0, false
	}
	switch n.text {
	case "nan":
		return nan(), true
	case "inf":
		return posInf(), true
	case "-inf":
		return negInf(), true
	}
	v, err := strconv.ParseFloat(n.text, 64)
	return v, err == nil
}

// Bool returns the value of a Bool node.
func (n *Node) Bool() (bool, bool) {
	if n.kind != Bool {
		return false, false
	}
	return n.text == "true", true
}

// Get returns the member of a table with the given key.
func (n *Node) Get(key string) (*Node, bool) {
	c, ok := n.tbl[key]
	return c, ok
}

// Set stores child under key in a table node, replacing any previous member.
// It panics if n is not a table.
func (n *Node) Set(key string, child *Node) {
	if n.kind != Table {
		panic("toml: Set on a non-table node")
	}
	n.tbl[key] = child
}

// Keys returns the keys of a table in ascending code-point order.
func (n *Node) Keys() []string {
	keys := make([]string, 0, len(n.tbl))
	for k := range n.tbl {
		keys = append(keys, k)
	}
	sort.Strings(keys) // byte order of UTF-8 equals code point order
	return keys
}

// Len returns the number of members of a table or elements of an array.
func (n *Node) Len() int {
	if n.kind == Table {
		return len(n.tbl)
	}
	return len(n.arr)
}

// Index returns element i of an array.
func (n *Node) Index(i int) *Node { return n.arr[i] }

// Append adds elem to an array node. It panics if n is not an array.
func (n *Node) Append(elem *Node) {
	if n.kind != Array {
		panic("toml: Append on a non-array node")
	}
	n.arr = append(n.arr, elem)
}
