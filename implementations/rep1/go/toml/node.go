package toml

import "sort"

// ValueType names the type of a scalar [Value]. The constants are the exact
// "type" strings used by tagged JSON.
type ValueType string

// The scalar types.
const (
	String        ValueType = "string"
	Integer       ValueType = "integer"
	Float         ValueType = "float"
	Bool          ValueType = "bool"
	DateTime      ValueType = "datetime"       // date, time and offset
	DateTimeLocal ValueType = "datetime-local" // date and time, no offset
	DateLocal     ValueType = "date-local"
	TimeLocal     ValueType = "time-local"
)

func (t ValueType) valid() bool {
	switch t {
	case String, Integer, Float, Bool, DateTime, DateTimeLocal, DateLocal, TimeLocal:
		return true
	}
	return false
}

// Node is a node of a TOML document tree: a [*Table], an [*Array] or a
// [*Value].
type Node interface {
	isNode()
}

// Value is a scalar. Text holds its canonical textual form:
//
//   - String: the string itself, after escape processing.
//   - Integer: decimal, e.g. "-17".
//   - Float: "nan", "inf", "-inf", or 17 significant digits in scientific
//     notation such as "3.1415000000000002e+00" (the %.16e format).
//   - Bool: "true" or "false".
//   - the date/time types: RFC 3339 text with an uppercase "T" separator,
//     trailing fractional zeros removed and "Z" for a zero offset.
type Value struct {
	Type ValueType
	Text string
}

// Array is an ordered list of nodes, either an array literal or an array of
// tables (created by [[header]] lines).
type Array struct {
	Elems []Node

	aot bool // created by [[...]]
}

// Table is a TOML table: a mapping from keys to nodes.
type Table struct {
	m map[string]Node

	// Provenance flags used while parsing (see the table rules in the spec).
	explicit bool // opened by a [header] or written as an inline table
	dotted   bool // created as an intermediate segment of a dotted key
	sealed   bool // part of a closed inline table
}

func (*Table) isNode() {}
func (*Array) isNode() {}
func (*Value) isNode() {}

// NewTable returns an empty table.
func NewTable() *Table { return &Table{m: make(map[string]Node)} }

// Len returns the number of keys in the table.
func (t *Table) Len() int { return len(t.m) }

// Get returns the node stored under key.
func (t *Table) Get(key string) (Node, bool) {
	n, ok := t.m[key]
	return n, ok
}

// Set stores n under key, replacing any previous node.
func (t *Table) Set(key string, n Node) { t.m[key] = n }

// Keys returns the table's keys in ascending code-point order.
func (t *Table) Keys() []string {
	keys := make([]string, 0, len(t.m))
	for k := range t.m {
		keys = append(keys, k)
	}
	// Go string comparison is bytewise, which for UTF-8 equals code point order.
	sort.Strings(keys)
	return keys
}
