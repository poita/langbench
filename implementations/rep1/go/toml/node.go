package toml

import "sort"

// Type identifies the kind of a scalar [Value].
type Type uint8

// The scalar types.
const (
	TypeString Type = iota
	TypeInteger
	TypeFloat
	TypeBool
	TypeDatetime      // date and time with an offset
	TypeDatetimeLocal // date and time without an offset
	TypeDateLocal     // date only
	TypeTimeLocal     // time only
)

var typeNames = [...]string{
	TypeString:        "string",
	TypeInteger:       "integer",
	TypeFloat:         "float",
	TypeBool:          "bool",
	TypeDatetime:      "datetime",
	TypeDatetimeLocal: "datetime-local",
	TypeDateLocal:     "date-local",
	TypeTimeLocal:     "time-local",
}

// String returns the type's name as used in tagged JSON ("string",
// "datetime-local", ...).
func (t Type) String() string {
	if int(t) < len(typeNames) {
		return typeNames[t]
	}
	return "invalid"
}

// ParseType returns the Type with the given tagged-JSON name.
func ParseType(name string) (Type, bool) {
	for i, n := range typeNames {
		if n == name {
			return Type(i), true
		}
	}
	return 0, false
}

// Node is a node of a TOML document tree: a *Table, an *Array or a *Value.
type Node interface {
	isNode()
}

// Value is a scalar. Text holds its canonical text form:
//
//   - string: the string itself, after escape processing;
//   - integer: decimal, with a leading "-" when negative;
//   - float: "inf", "-inf", "nan", or 17 significant digits in scientific
//     notation such as "1.0000000000000000e+00";
//   - bool: "true" or "false";
//   - date-times: "YYYY-MM-DDTHH:MM:SS[.frac][Z|+HH:MM]" and its local
//     variants, with trailing fractional zeros removed.
type Value struct {
	Type Type
	Text string
}

// Array is an ordered list of nodes. Tables created with [[header]] syntax
// are stored in an Array too.
type Array struct {
	Items []Node

	// tables is set for arrays created by [[header]] lines; only those may
	// be extended by later headers.
	tables bool
}

type tableState uint8

const (
	stateImplicit tableState = iota // created as a segment of another header
	stateExplicit                   // opened by a [header]
	stateDotted                     // created by a dotted key
	stateInline                     // an inline table literal
)

// Table maps keys to nodes.
type Table struct {
	entries map[string]Node
	state   tableState
}

func (*Table) isNode() {}
func (*Array) isNode() {}
func (*Value) isNode() {}

// NewTable returns an empty table.
func NewTable() *Table {
	return &Table{entries: make(map[string]Node)}
}

// NewArray returns an array holding items.
func NewArray(items ...Node) *Array {
	return &Array{Items: items}
}

// Get returns the node stored under key.
func (t *Table) Get(key string) (Node, bool) {
	n, ok := t.entries[key]
	return n, ok
}

// Set stores n under key, replacing any previous entry.
func (t *Table) Set(key string, n Node) {
	t.entries[key] = n
}

// Len returns the number of keys in the table.
func (t *Table) Len() int { return len(t.entries) }

// Keys returns the table's keys in ascending code point order.
func (t *Table) Keys() []string {
	keys := make([]string, 0, len(t.entries))
	for k := range t.entries {
		keys = append(keys, k)
	}
	// Byte-wise order of valid UTF-8 equals code point order.
	sort.Strings(keys)
	return keys
}

// Lookup follows path through nested tables (and the last element of
// arrays of tables) and returns the node it reaches.
func (t *Table) Lookup(path ...string) (Node, bool) {
	var cur Node = t
	for _, k := range path {
		switch c := cur.(type) {
		case *Table:
			n, ok := c.entries[k]
			if !ok {
				return nil, false
			}
			cur = n
		case *Array:
			if len(c.Items) == 0 {
				return nil, false
			}
			tbl, ok := c.Items[len(c.Items)-1].(*Table)
			if !ok {
				return nil, false
			}
			n, ok := tbl.entries[k]
			if !ok {
				return nil, false
			}
			cur = n
		default:
			return nil, false
		}
	}
	return cur, true
}
