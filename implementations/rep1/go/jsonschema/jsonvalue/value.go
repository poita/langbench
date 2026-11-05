package jsonvalue

// Kind identifies the JSON type of a Value.
type Kind uint8

// The JSON types.
const (
	KindNull Kind = iota
	KindBool
	KindNumber
	KindString
	KindArray
	KindObject
)

func (k Kind) String() string {
	switch k {
	case KindNull:
		return "null"
	case KindBool:
		return "boolean"
	case KindNumber:
		return "number"
	case KindString:
		return "string"
	case KindArray:
		return "array"
	case KindObject:
		return "object"
	}
	return "invalid"
}

// Value is a JSON value. The zero Value is null. Values are small and cheap
// to copy; arrays and objects share their backing storage between copies and
// must be treated as immutable once built.
type Value struct {
	kind Kind
	b    bool
	s    string
	n    *Number
	arr  []Value
	obj  *Object
}

// Null returns the JSON null value.
func Null() Value { return Value{} }

// NewBool returns a JSON boolean.
func NewBool(b bool) Value { return Value{kind: KindBool, b: b} }

// NewNumber returns a JSON number.
func NewNumber(n Number) Value { return Value{kind: KindNumber, n: &n} }

// NewString returns a JSON string.
func NewString(s string) Value { return Value{kind: KindString, s: s} }

// NewArray returns a JSON array holding elems (not copied).
func NewArray(elems []Value) Value { return Value{kind: KindArray, arr: elems} }

// NewObjectValue returns a JSON object value wrapping o.
func NewObjectValue(o *Object) Value { return Value{kind: KindObject, obj: o} }

// Kind returns the JSON type of v.
func (v Value) Kind() Kind { return v.kind }

// Bool returns the boolean held by v (false if v is not a boolean).
func (v Value) Bool() bool { return v.b }

// Number returns the number held by v (zero if v is not a number).
func (v Value) Number() Number {
	if v.n == nil {
		return Number{}
	}
	return *v.n
}

// Str returns the string held by v ("" if v is not a string).
func (v Value) Str() string { return v.s }

// Array returns the elements of v (nil if v is not an array). The slice is
// shared with v and must not be modified.
func (v Value) Array() []Value { return v.arr }

// Object returns the object held by v (nil if v is not an object).
func (v Value) Object() *Object { return v.obj }

// Member is one key/value pair of an object.
type Member struct {
	Key   string
	Value Value
}

// indexThreshold is the member count above which an Object builds a hash
// index; below it a linear scan is faster.
const indexThreshold = 8

// Object is an ordered JSON object. Member i has the stable position i.
type Object struct {
	members []Member
	index   map[string]int
}

// NewObject builds an Object from members, which must have distinct keys.
// The slice is retained, not copied.
func NewObject(members []Member) *Object {
	o := &Object{members: members}
	if len(members) > indexThreshold {
		o.index = make(map[string]int, len(members))
		for i := range members {
			o.index[members[i].Key] = i
		}
	}
	return o
}

// Len returns the number of members.
func (o *Object) Len() int {
	if o == nil {
		return 0
	}
	return len(o.members)
}

// Members returns the members in document order. The slice is shared with the
// object and must not be modified.
func (o *Object) Members() []Member {
	if o == nil {
		return nil
	}
	return o.members
}

// Get returns a pointer to the value stored under key, or nil if absent.
func (o *Object) Get(key string) *Value {
	if o == nil {
		return nil
	}
	if o.index != nil {
		if i, ok := o.index[key]; ok {
			return &o.members[i].Value
		}
		return nil
	}
	for i := range o.members {
		if o.members[i].Key == key {
			return &o.members[i].Value
		}
	}
	return nil
}

// Has reports whether key is a member of the object.
func (o *Object) Has(key string) bool { return o.Get(key) != nil }

// Equal implements JSON equality: values of different types are never equal,
// numbers are compared exactly, arrays element-wise and objects by key set
// and per-key values, regardless of member order.
func Equal(a, b Value) bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case KindNull:
		return true
	case KindBool:
		return a.b == b.b
	case KindNumber:
		return a.n.Equal(*b.n)
	case KindString:
		return a.s == b.s
	case KindArray:
		if len(a.arr) != len(b.arr) {
			return false
		}
		for i := range a.arr {
			if !Equal(a.arr[i], b.arr[i]) {
				return false
			}
		}
		return true
	case KindObject:
		if a.obj.Len() != b.obj.Len() {
			return false
		}
		for _, m := range a.obj.members {
			o := b.obj.Get(m.Key)
			if o == nil || !Equal(m.Value, *o) {
				return false
			}
		}
		return true
	}
	return false
}

// Hash returns a hash of v that is consistent with Equal: equal values have
// equal hashes. Object hashing is independent of member order.
func Hash(v Value) uint64 {
	const prime = 1099511628211
	switch v.kind {
	case KindNull:
		return 0x9e3779b97f4a7c15
	case KindBool:
		if v.b {
			return 0x1234567
		}
		return 0x7654321
	case KindNumber:
		return v.n.hash()
	case KindString:
		return hashString(v.s)
	case KindArray:
		h := uint64(0xcbf29ce484222325)
		for i := range v.arr {
			h ^= Hash(v.arr[i])
			h *= prime
			h ^= h >> 31
		}
		return h
	case KindObject:
		var h uint64 = 0xabcdef
		for _, m := range v.obj.Members() {
			// Commutative combination so that member order is irrelevant.
			x := hashString(m.Key)*31 ^ Hash(m.Value)
			x ^= x >> 29
			x *= 0xbf58476d1ce4e5b9
			x ^= x >> 32
			h += x
		}
		return h
	}
	return 0
}

func hashString(s string) uint64 {
	h := uint64(14695981039346656037)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}
