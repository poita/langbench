package toml

import (
	"math"
	"sort"
	"strconv"
)

// Kind identifies the type of a [Node].
type Kind uint8

// The node kinds. The scalar kinds correspond to the "type" names of tagged
// JSON (see [Kind.TypeName]).
const (
	KindTable         Kind = iota // a table: key/value members
	KindArray                     // an array of nodes
	KindString                    // a string
	KindInteger                   // a 64-bit signed integer
	KindFloat                     // an IEEE-754 binary64 float
	KindBool                      // true or false
	KindDatetime                  // date-time with offset
	KindDatetimeLocal             // date-time without offset
	KindDateLocal                 // calendar date
	KindTimeLocal                 // time of day

	kindRaw // internal: a bare JSON string while reading tagged JSON
)

var typeNames = [...]string{
	KindString:        "string",
	KindInteger:       "integer",
	KindFloat:         "float",
	KindBool:          "bool",
	KindDatetime:      "datetime",
	KindDatetimeLocal: "datetime-local",
	KindDateLocal:     "date-local",
	KindTimeLocal:     "time-local",
}

// TypeName returns the tagged-JSON "type" name of a scalar kind, or "" for
// tables and arrays.
func (k Kind) TypeName() string {
	if int(k) < len(typeNames) {
		return typeNames[k]
	}
	return ""
}

// kindFromTypeName is the inverse of TypeName.
func kindFromTypeName(s string) (Kind, bool) {
	for k, n := range typeNames {
		if n != "" && n == s {
			return Kind(k), true
		}
	}
	return 0, false
}

// Provenance flags kept on table and array nodes while parsing (TOML 1.0.0
// table-definition rules).
const (
	flagExplicit uint8 = 1 << iota // opened by [header] or written as an inline table
	flagDotted                     // created as an intermediate segment of a dotted key
	flagSealed                     // part of a closed inline table
	flagAOT                        // array created by [[header]]
)

// Node is one element of a TOML document tree: a table, an array or a scalar.
// The zero value is not useful; create nodes with the New* functions or by
// parsing.
type Node struct {
	kind  Kind
	flags uint8
	text  string           // scalars: canonical text (string value for strings)
	tbl   map[string]*Node // tables
	items []*Node          // arrays
}

// NewTable returns an empty table.
func NewTable() *Node { return &Node{kind: KindTable, tbl: map[string]*Node{}} }

// NewArray returns an array holding items.
func NewArray(items ...*Node) *Node { return &Node{kind: KindArray, items: items} }

// NewString returns a string node.
func NewString(s string) *Node { return &Node{kind: KindString, text: s} }

// NewInteger returns an integer node.
func NewInteger(v int64) *Node { return &Node{kind: KindInteger, text: strconv.FormatInt(v, 10)} }

// NewFloat returns a float node in the canonical 17-significant-digit form.
func NewFloat(v float64) *Node { return &Node{kind: KindFloat, text: formatFloat(v)} }

// NewBool returns a boolean node.
func NewBool(v bool) *Node { return &Node{kind: KindBool, text: strconv.FormatBool(v)} }

// NewDatetime returns a date/time node of the given kind (KindDatetime,
// KindDatetimeLocal, KindDateLocal or KindTimeLocal) with canonical text. The
// text is not validated.
func NewDatetime(kind Kind, text string) *Node { return &Node{kind: kind, text: text} }

func newScalar(kind Kind, text string) *Node { return &Node{kind: kind, text: text} }

// Kind returns the node's kind.
func (n *Node) Kind() Kind { return n.kind }

// IsTable reports whether n is a table.
func (n *Node) IsTable() bool { return n.kind == KindTable }

// IsArray reports whether n is an array.
func (n *Node) IsArray() bool { return n.kind == KindArray }

// Text returns the canonical text of a scalar: the decoded value of a string,
// the decimal form of an integer, the 17-digit form of a float, "true" or
// "false", or the canonical date-time text. It returns "" for tables and arrays.
func (n *Node) Text() string { return n.text }

// Int64 returns the value of an integer node (0 for other kinds).
func (n *Node) Int64() int64 {
	if n.kind != KindInteger {
		return 0
	}
	v, _ := strconv.ParseInt(n.text, 10, 64)
	return v
}

// Float64 returns the value of a float node (0 for other kinds).
func (n *Node) Float64() float64 {
	if n.kind != KindFloat {
		return 0
	}
	switch n.text {
	case "inf":
		return math.Inf(1)
	case "-inf":
		return math.Inf(-1)
	case "nan":
		return math.NaN()
	}
	v, _ := strconv.ParseFloat(n.text, 64)
	return v
}

// Bool returns the value of a boolean node (false for other kinds).
func (n *Node) Bool() bool { return n.kind == KindBool && n.text == "true" }

// Get returns the member of a table with the given key, or nil.
func (n *Node) Get(key string) *Node {
	if n.kind != KindTable {
		return nil
	}
	return n.tbl[key]
}

// Keys returns the keys of a table in ascending (code point) order.
func (n *Node) Keys() []string {
	if n.kind != KindTable {
		return nil
	}
	return sortedKeys(n.tbl)
}

// Set stores child under key in a table, replacing any previous member.
// It panics if n is not a table.
func (n *Node) Set(key string, child *Node) {
	if n.kind != KindTable {
		panic("toml: Set on a non-table node")
	}
	n.tbl[key] = child
}

// Len returns the number of members of a table or elements of an array.
func (n *Node) Len() int {
	switch n.kind {
	case KindTable:
		return len(n.tbl)
	case KindArray:
		return len(n.items)
	}
	return 0
}

// Items returns the elements of an array. The slice must not be modified.
func (n *Node) Items() []*Node { return n.items }

// At returns element i of an array.
func (n *Node) At(i int) *Node { return n.items[i] }

// Append adds child to the end of an array. It panics if n is not an array.
func (n *Node) Append(child *Node) {
	if n.kind != KindArray {
		panic("toml: Append on a non-array node")
	}
	n.items = append(n.items, child)
}

// sortedKeys returns the keys of m sorted bytewise, which for UTF-8 equals
// code point order.
func sortedKeys(m map[string]*Node) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
