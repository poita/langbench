package vm

import "langvm/bytecode"

// Value is a Vellum runtime value. Its dynamic Go type is one of:
//
//	int64     Int
//	float64   Float
//	bool      Bool
//	rune      Char
//	[]rune    Str (immutable; never modified after creation)
//	Unit      the unit value
//	*List     list
//	*Map      map
//	*Tuple    tuple
//	*Struct   struct instance
//	*Enum     enum value
//	*Closure  closure
type Value = any

// Unit is the type of the unit value.
type Unit struct{}

// List is a mutable list object.
type List struct{ Elems []Value }

// Tuple is an immutable tuple.
type Tuple struct{ E []Value }

// Struct is an immutable struct instance.
type Struct struct {
	Decl int32
	F    []Value
}

// Enum is an immutable enum value.
type Enum struct {
	Decl    int32
	Variant int32
	P       []Value
}

// Closure is a function together with its captured values.
type Closure struct {
	Fn int32
	Up []Value
}

const (
	optionDecl = 0
	someVar    = 0
	noneVar    = 1
	resultDecl = 1
	okVar      = 0
	errVar     = 1
)

var unit Value = Unit{}

var noneValue Value = &Enum{Decl: optionDecl, Variant: noneVar}

func some(v Value) Value      { return &Enum{Decl: optionDecl, Variant: someVar, P: []Value{v}} }
func newList(e []Value) *List { return &List{Elems: e} }

// ctorOf returns the head-constructor code of a value, matching
// types.Type.Ctor.
func ctorOf(v Value) int {
	switch x := v.(type) {
	case int64:
		return 0
	case float64:
		return 1
	case bool:
		return 2
	case rune:
		return 3
	case []rune:
		return 4
	case Unit:
		return 5
	case *List:
		return 6
	case *Map:
		return 7
	case *Struct:
		return 8 + int(x.Decl)
	case *Enum:
		return 8 + int(x.Decl)
	}
	return -1
}

func constValue(c bytecode.Const) Value {
	switch c.Kind {
	case bytecode.ConstInt:
		return c.I
	case bytecode.ConstFloat:
		return c.F
	case bytecode.ConstChar:
		return rune(c.I)
	}
	s := c.S
	if s == nil {
		s = []rune{}
	}
	return s
}

// equal implements structural equality (SPEC.md 10.4).
func equal(a, b Value) bool {
	switch x := a.(type) {
	case int64:
		return x == b.(int64)
	case float64:
		return x == b.(float64)
	case bool:
		return x == b.(bool)
	case rune:
		return x == b.(rune)
	case []rune:
		y := b.([]rune)
		if len(x) != len(y) {
			return false
		}
		for i := range x {
			if x[i] != y[i] {
				return false
			}
		}
		return true
	case Unit:
		return true
	case *List:
		y := b.(*List)
		if len(x.Elems) != len(y.Elems) {
			return false
		}
		for i := range x.Elems {
			if !equal(x.Elems[i], y.Elems[i]) {
				return false
			}
		}
		return true
	case *Map:
		y := b.(*Map)
		if x.live != y.live {
			return false
		}
		for i := range x.entries {
			e := &x.entries[i]
			if e.dead {
				continue
			}
			ov, ok := y.get(e.key)
			if !ok || !equal(e.val, ov) {
				return false
			}
		}
		return true
	case *Tuple:
		y := b.(*Tuple)
		for i := range x.E {
			if !equal(x.E[i], y.E[i]) {
				return false
			}
		}
		return true
	case *Struct:
		y := b.(*Struct)
		for i := range x.F {
			if !equal(x.F[i], y.F[i]) {
				return false
			}
		}
		return true
	case *Enum:
		y := b.(*Enum)
		if x.Variant != y.Variant {
			return false
		}
		for i := range x.P {
			if !equal(x.P[i], y.P[i]) {
				return false
			}
		}
		return true
	}
	return false
}

func cmpRunes(x, y []rune) int {
	n := len(x)
	if len(y) < n {
		n = len(y)
	}
	for i := 0; i < n; i++ {
		if x[i] != y[i] {
			if x[i] < y[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(x) < len(y):
		return -1
	case len(x) > len(y):
		return 1
	}
	return 0
}

// less and lessEq implement the ordering of section 10.4 on Ord types.
func less(a, b Value) bool {
	switch x := a.(type) {
	case int64:
		return x < b.(int64)
	case float64:
		return x < b.(float64)
	case bool:
		return !x && b.(bool)
	case rune:
		return x < b.(rune)
	case []rune:
		return cmpRunes(x, b.([]rune)) < 0
	}
	return false
}

func lessEq(a, b Value) bool {
	switch x := a.(type) {
	case int64:
		return x <= b.(int64)
	case float64:
		return x <= b.(float64)
	case bool:
		return !x || b.(bool)
	case rune:
		return x <= b.(rune)
	case []rune:
		return cmpRunes(x, b.([]rune)) <= 0
	}
	return false
}

// ---------------------------------------------------------------- maps

type mapEntry struct {
	key, val Value
	dead     bool
}

// Map is an insertion-ordered hash map object.
type Map struct {
	index   map[any]int
	entries []mapEntry
	live    int
}

func newMap() *Map { return &Map{index: map[any]int{}} }

func mapKey(k Value) any {
	if s, ok := k.([]rune); ok {
		return string(s)
	}
	return k
}

func (m *Map) get(k Value) (Value, bool) {
	i, ok := m.index[mapKey(k)]
	if !ok {
		return nil, false
	}
	return m.entries[i].val, true
}

func (m *Map) set(k, v Value) {
	mk := mapKey(k)
	if i, ok := m.index[mk]; ok {
		m.entries[i].val = v
		return
	}
	m.index[mk] = len(m.entries)
	m.entries = append(m.entries, mapEntry{key: k, val: v})
	m.live++
}

func (m *Map) del(k Value) bool {
	mk := mapKey(k)
	i, ok := m.index[mk]
	if !ok {
		return false
	}
	delete(m.index, mk)
	m.entries[i] = mapEntry{dead: true}
	m.live--
	if len(m.entries) > 32 && m.live*2 < len(m.entries) {
		m.compact()
	}
	return true
}

func (m *Map) compact() {
	out := make([]mapEntry, 0, m.live)
	for _, e := range m.entries {
		if !e.dead {
			m.index[mapKey(e.key)] = len(out)
			out = append(out, e)
		}
	}
	m.entries = out
}

func (m *Map) clear() {
	m.index = map[any]int{}
	m.entries = nil
	m.live = 0
}

func (m *Map) copyMap() *Map {
	n := &Map{index: make(map[any]int, m.live), entries: make([]mapEntry, 0, m.live)}
	for _, e := range m.entries {
		if !e.dead {
			n.index[mapKey(e.key)] = len(n.entries)
			n.entries = append(n.entries, e)
		}
	}
	n.live = m.live
	return n
}
