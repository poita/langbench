package tmpl

// A Value is a value of the template language. The concrete Go types are:
//
//	string        a string (a sequence of Unicode code points)
//	int64         an integer
//	float64       a float
//	bool          a boolean (an integer in arithmetic, comparisons and indexing)
//	None          the none value
//	[]Value       a list
//	*Dict         a dict with string keys, ordered by insertion
//
// The undefined value is available as Undefined. Values passed to Render are
// shared with the template and never modified.
type Value = any

type noneType struct{}

type undefinedType struct{}

// None is the template language's none value.
var None Value = noneType{}

// Undefined is the template language's undefined value. Most uses of it
// (printing, operators, attribute access, ...) are errors.
var Undefined Value = undefinedType{}

// A Dict is an insertion-ordered mapping from string keys to values.
type Dict struct {
	keys []string
	m    map[string]Value
}

// NewDict returns an empty dict with room for n members.
func NewDict(n int) *Dict {
	return &Dict{keys: make([]string, 0, n), m: make(map[string]Value, n)}
}

// Set binds key to v. Rebinding an existing key keeps its position.
func (d *Dict) Set(key string, v Value) {
	if _, ok := d.m[key]; !ok {
		d.keys = append(d.keys, key)
	}
	d.m[key] = v
}

// Get returns the value bound to key.
func (d *Dict) Get(key string) (Value, bool) {
	v, ok := d.m[key]
	return v, ok
}

// Keys returns the keys in insertion order. The slice must not be modified.
func (d *Dict) Keys() []string { return d.keys }

// Len returns the number of members.
func (d *Dict) Len() int { return len(d.keys) }

// loopInfo is the value of the loop variable inside a for body.
type loopInfo struct {
	index0, length int
}

// macroVal is a macro defined by a macro statement.
type macroVal struct {
	def *macroStmt
	sc  *scope
	r   *rendering
}

// superVal is the value of the name super inside a block body.
type superVal struct {
	r     *rendering
	name  string
	index int
}

// rangeFn is the built-in range function.
type rangeFn struct{}
