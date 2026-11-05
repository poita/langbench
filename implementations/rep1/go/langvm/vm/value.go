package vm

import "math"

// Kind is the runtime tag of a value. The first eight kinds double as the
// "head constructor" ids used by trait dispatch (SPEC 8.2): Int, Float, Bool,
// Char, Str, Unit, List, Map.
type Kind uint8

// Runtime kinds.
const (
	KInt Kind = iota
	KFloat
	KBool
	KChar
	KStr
	KUnit
	KList
	KMap
	KTuple
	KClosure
	KStruct
	KEnum
)

// Obj is a heap object, or (for scalar values) a shared per-kind sentinel
// that only carries the tag.
//
//   - KStr:     S holds the scalar values.
//   - KList:    V holds the elements (growable).
//   - KMap:     M holds the insertion-ordered map.
//   - KTuple:   V holds the components.
//   - KStruct:  Decl is the declaration id, V the fields in declaration order.
//   - KEnum:    Decl is the declaration id, Var the variant index, V the
//     payloads. Payload-less variants are shared objects.
//   - KClosure: Decl is the function index, V the captured values.
type Obj struct {
	Kind Kind
	Var  int32
	Decl int32
	V    []Value
	S    []rune
	M    *Map
}

// Value is a small tagged cell: scalars live inline in N (Int, Float bits,
// Bool, Char), everything else is a reference in P. P is never nil in a
// well-formed value; for scalars it points at a shared sentinel.
type Value struct {
	N int64
	P *Obj
}

var (
	tagInt   = &Obj{Kind: KInt}
	tagFloat = &Obj{Kind: KFloat}
	tagBool  = &Obj{Kind: KBool}
	tagChar  = &Obj{Kind: KChar}
	tagUnit  = &Obj{Kind: KUnit}
	emptyStr = &Obj{Kind: KStr}

	// noneObj is the shared Option::None value (declaration 0, variant 1).
	noneObj = &Obj{Kind: KEnum, Decl: 0, Var: 1}
)

// Declaration ids and variant indexes of the prelude enums.
const (
	OptionDecl = 0
	ResultDecl = 1
	VarSome    = 0
	VarNone    = 1
	VarOk      = 0
	VarErr     = 1
)

// Unit is the unit value.
var Unit = Value{P: tagUnit}

// NoneV is Option::None.
var NoneV = Value{P: noneObj}

// Int makes an Int value.
func Int(n int64) Value { return Value{N: n, P: tagInt} }

// Float makes a Float value.
func Float(f float64) Value { return Value{N: int64(math.Float64bits(f)), P: tagFloat} }

// Bool makes a Bool value.
func Bool(b bool) Value {
	if b {
		return Value{N: 1, P: tagBool}
	}
	return Value{P: tagBool}
}

// Char makes a Char value.
func Char(r rune) Value { return Value{N: int64(r), P: tagChar} }

// Str makes a Str value that shares (does not copy) the scalar slice.
func Str(s []rune) Value {
	if len(s) == 0 {
		return Value{P: emptyStr}
	}
	return Value{P: &Obj{Kind: KStr, S: s}}
}

// GoStr makes a Str value from a Go string.
func GoStr(s string) Value { return Str([]rune(s)) }

// List makes a list that takes ownership of the slice.
func List(vs []Value) Value { return Value{P: &Obj{Kind: KList, V: vs}} }

// Tuple makes a tuple that takes ownership of the slice.
func Tuple(vs []Value) Value { return Value{P: &Obj{Kind: KTuple, V: vs}} }

// MapV wraps a map.
func MapV(m *Map) Value { return Value{P: &Obj{Kind: KMap, M: m}} }

// Some makes Option::Some(v).
func Some(v Value) Value {
	return Value{P: &Obj{Kind: KEnum, Decl: OptionDecl, Var: VarSome, V: []Value{v}}}
}

// Ok makes Result::Ok(v).
func Ok(v Value) Value {
	return Value{P: &Obj{Kind: KEnum, Decl: ResultDecl, Var: VarOk, V: []Value{v}}}
}

// Err makes Result::Err(v).
func Err(v Value) Value {
	return Value{P: &Obj{Kind: KEnum, Decl: ResultDecl, Var: VarErr, V: []Value{v}}}
}

// I returns the Int payload.
func (v Value) I() int64 { return v.N }

// F returns the Float payload.
func (v Value) F() float64 { return math.Float64frombits(uint64(v.N)) }

// B returns the Bool payload.
func (v Value) B() bool { return v.N != 0 }

// C returns the Char payload.
func (v Value) C() rune { return rune(v.N) }

// S returns the scalars of a Str value (do not modify).
func (v Value) S() []rune { return v.P.S }

// Items returns the element slice of a list, tuple, struct or enum value.
func (v Value) Items() []Value { return v.P.V }

// Equal is structural equality (SPEC 10.4).
func Equal(a, b Value) bool {
	switch a.P.Kind {
	case KInt, KBool, KChar:
		return a.N == b.N
	case KFloat:
		return a.F() == b.F()
	case KUnit:
		return true
	case KStr:
		return runesEqual(a.P.S, b.P.S)
	case KList, KTuple, KStruct:
		x, y := a.P.V, b.P.V
		if len(x) != len(y) {
			return false
		}
		for i := range x {
			if !Equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case KEnum:
		if a.P == b.P {
			return true
		}
		if a.P.Var != b.P.Var {
			return false
		}
		x, y := a.P.V, b.P.V
		for i := range x {
			if !Equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case KMap:
		x, y := a.P.M, b.P.M
		if x.Len() != y.Len() {
			return false
		}
		for i := range x.ents {
			e := &x.ents[i]
			if e.dead {
				continue
			}
			v, ok := y.Get(e.K)
			if !ok || !Equal(e.V, v) {
				return false
			}
		}
		return true
	}
	return a.P == b.P // closures: not reachable in checked programs
}

func runesEqual(a, b []rune) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// CompareStr orders two scalar sequences lexicographically: -1, 0 or 1.
func CompareStr(a, b []rune) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	}
	return 0
}

// ----------------------------------------------------------------------- Map

type entry struct {
	K, V Value
	H    uint64
	dead bool
}

// Map is an insertion-ordered hash map whose keys are Int, Bool, Char or Str
// values: a vector of entries plus an open-addressing index into it.
type Map struct {
	ents []entry
	idx  []int32 // -1 empty, else position in ents (possibly a dead entry)
	live int
}

// NewMap returns an empty map.
func NewMap() *Map { return &Map{} }

// Len is the number of live entries.
func (m *Map) Len() int { return m.live }

func hashKey(k Value) uint64 {
	if k.P.Kind == KStr {
		h := uint64(14695981039346656037)
		for _, r := range k.P.S {
			h ^= uint64(r)
			h *= 1099511628211
		}
		return mix(h)
	}
	return mix(uint64(k.N))
}

func mix(x uint64) uint64 {
	x ^= x >> 33
	x *= 0xff51afd7ed558ccd
	x ^= x >> 33
	x *= 0xc4ceb9fe1a85ec53
	x ^= x >> 33
	return x
}

func keyEq(a, b Value) bool {
	if a.P.Kind == KStr {
		return runesEqual(a.P.S, b.P.S)
	}
	return a.N == b.N
}

func (m *Map) find(k Value, h uint64) int {
	if len(m.idx) == 0 {
		return -1
	}
	mask := uint64(len(m.idx) - 1)
	for i := h & mask; ; i = (i + 1) & mask {
		p := m.idx[i]
		if p < 0 {
			return -1
		}
		e := &m.ents[p]
		if !e.dead && e.H == h && keyEq(e.K, k) {
			return int(p)
		}
	}
}

// Get looks a key up.
func (m *Map) Get(k Value) (Value, bool) {
	if p := m.find(k, hashKey(k)); p >= 0 {
		return m.ents[p].V, true
	}
	return Value{}, false
}

// Has reports whether the key is present.
func (m *Map) Has(k Value) bool { return m.find(k, hashKey(k)) >= 0 }

func (m *Map) rebuild(capacity int) {
	// Compact dead entries away and rebuild the index.
	if m.live != len(m.ents) {
		out := m.ents[:0]
		for _, e := range m.ents {
			if !e.dead {
				out = append(out, e)
			}
		}
		for i := len(out); i < len(m.ents); i++ {
			m.ents[i] = entry{}
		}
		m.ents = out
	}
	n := 8
	for n < capacity*2 {
		n <<= 1
	}
	m.idx = make([]int32, n)
	for i := range m.idx {
		m.idx[i] = -1
	}
	mask := uint64(n - 1)
	for p := range m.ents {
		i := m.ents[p].H & mask
		for m.idx[i] >= 0 {
			i = (i + 1) & mask
		}
		m.idx[i] = int32(p)
	}
}

// Set inserts or updates a key. An existing key keeps its position.
func (m *Map) Set(k, v Value) {
	h := hashKey(k)
	if p := m.find(k, h); p >= 0 {
		m.ents[p].V = v
		return
	}
	// slots used in idx = len(ents) (live + dead); keep load factor <= 1/2
	if (len(m.ents)+1)*2 > len(m.idx) {
		m.rebuild(m.live + 1)
	}
	m.ents = append(m.ents, entry{K: k, V: v, H: h})
	m.live++
	mask := uint64(len(m.idx) - 1)
	i := h & mask
	for m.idx[i] >= 0 {
		i = (i + 1) & mask
	}
	m.idx[i] = int32(len(m.ents) - 1)
}

// Del removes a key, reporting whether it was present.
func (m *Map) Del(k Value) bool {
	p := m.find(k, hashKey(k))
	if p < 0 {
		return false
	}
	m.ents[p].dead = true
	m.ents[p].K = Value{}
	m.ents[p].V = Value{}
	m.live--
	if len(m.ents) > 16 && m.live*2 < len(m.ents) {
		m.rebuild(m.live)
	}
	return true
}

// Clear removes every entry.
func (m *Map) Clear() {
	m.ents = nil
	m.idx = nil
	m.live = 0
}

// Copy returns a new map with the same entries in the same order.
func (m *Map) Copy() *Map {
	c := &Map{}
	for i := range m.ents {
		if !m.ents[i].dead {
			c.Set(m.ents[i].K, m.ents[i].V)
		}
	}
	return c
}

// Each calls f for every live entry in insertion order. f must not mutate
// the map.
func (m *Map) Each(f func(k, v Value)) {
	for i := range m.ents {
		if !m.ents[i].dead {
			f(m.ents[i].K, m.ents[i].V)
		}
	}
}
